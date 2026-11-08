#!/usr/bin/env python3
"""Exercise real Sparkle archive/feed signatures over loopback; never install or publish."""
from __future__ import annotations

import argparse
import base64
from datetime import datetime, timezone
import functools
import hashlib
from http.server import SimpleHTTPRequestHandler, ThreadingHTTPServer
import json
from pathlib import Path
import plistlib
import subprocess
import tempfile
import threading
import urllib.request
import xml.etree.ElementTree as ET
import zipfile

from sparkle_setup import ACCOUNT, ARCHIVE_SHA256, DEFAULT_CONFIG, VERSION, configure, read_public_key, verified_tools
from sparkle_feed import finalize_signed_appcast, sign_feed, verify_feed
from macos_release import parse_item, preview_appcast, sparkle, version_info

SPARKLE = "http://www.andymatuschak.org/xml-namespaces/sparkle"


def command(tool, arguments, rejection=False):
    result = subprocess.run([str(tool), "--account", ACCOUNT] + arguments,
                            capture_output=True, text=True, timeout=60)
    if rejection:
        if not result.returncode or "failed to pass signing verification" not in result.stdout:
            raise ValueError("Tampered artifact was not rejected specifically for an invalid signature")
    elif result.returncode:
        raise ValueError("Sparkle signature operation failed; inspect local Keychain access")
    return result.stdout.strip()


class SilentHandler(SimpleHTTPRequestHandler):
    def log_message(self, *args):
        pass


def verify(output):
    output = Path(output)
    if output.exists():
        raise ValueError("Use a new output directory to preserve earlier signature evidence")
    public_key = read_public_key()
    if not public_key:
        raise ValueError("Initialize the fork's public configuration before this probe")
    tools = verified_tools()
    # Refuse a valid signature made by a different account than the checked-in key.
    configure(DEFAULT_CONFIG, tools / "generate_keys")
    signer = tools / "sign_update"
    checks = []
    with tempfile.TemporaryDirectory(prefix="nativ-sparkle-probe-") as directory:
        root = Path(directory)
        archive = root / "NativSparkleFixture-2.0.0.zip"
        info = {"CFBundleIdentifier": ACCOUNT + ".update-fixture", "CFBundleVersion": "2",
                "CFBundleShortVersionString": "2.0.0", "SUPublicEDKey": public_key}
        with zipfile.ZipFile(archive, "w") as zipped:
            zipped.writestr("NativSparkleFixture.app/Contents/Info.plist", plistlib.dumps(info))
            zipped.writestr("NativSparkleFixture.app/Contents/Resources/fixture.txt", "Signature transport fixture; not an installable application.\n")
        signature = command(signer, ["-p", str(archive)])
        if len(base64.b64decode(signature, validate=True)) != 64:
            raise ValueError("Sparkle did not produce a 64-byte Ed25519 signature")
        command(signer, ["--verify", str(archive), signature])
        checks.append("archive_signature_verified")

        server = ThreadingHTTPServer(("127.0.0.1", 0), functools.partial(SilentHandler, directory=str(root)))
        thread = threading.Thread(target=server.serve_forever, daemon=True)
        thread.start()
        try:
            base = f"http://127.0.0.1:{server.server_address[1]}"
            feed = root / "appcast.xml"
            feed.write_text(f'''<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="{SPARKLE}"><channel>
<title>Local integrity probe</title><item><title>Fixture 2.0.0</title>
<sparkle:version>2</sparkle:version><sparkle:shortVersionString>2.0.0</sparkle:shortVersionString>
<enclosure url="{base}/{archive.name}" length="{archive.stat().st_size}" type="application/octet-stream" sparkle:edSignature="{signature}"/>
</item></channel></rss>
''')
            command(signer, ["-p", str(feed)])
            command(signer, ["--verify", str(feed)])
            checks.append("feed_signature_verified")

            # Bypass environment proxies only for this explicitly loopback-only fixture.
            opener = urllib.request.build_opener(urllib.request.ProxyHandler({}))
            with opener.open(base + "/appcast.xml", timeout=5) as response:
                feed_bytes = response.read(1024 * 1024)
            received_feed = root / "received.xml"
            received_feed.write_bytes(feed_bytes)
            command(signer, ["--verify", str(received_feed)])
            enclosure = ET.fromstring(feed_bytes).find("./channel/item/enclosure")
            if enclosure is None or enclosure.get("url") != base + "/" + archive.name:
                raise ValueError("Unexpected fixture enclosure URL")
            with opener.open(enclosure.get("url"), timeout=5) as response:
                archive_bytes = response.read(1024 * 1024)
            if len(archive_bytes) != int(enclosure.get("length")):
                raise ValueError("Downloaded archive length mismatch")
            received_archive = root / "received.zip"
            received_archive.write_bytes(archive_bytes)
            command(signer, ["--verify", str(received_archive), enclosure.get("{" + SPARKLE + "}edSignature")])
            checks.append("loopback_download_verified")
        finally:
            server.shutdown()
            server.server_close()
            thread.join(timeout=5)

        received_archive.write_bytes(archive_bytes + b"tampered")
        command(signer, ["--verify", str(received_archive), signature], rejection=True)
        checks.append("tampered_archive_rejected")
        received_feed.write_bytes(feed_bytes.replace(b"Local integrity probe", b"Tampered integrity probe", 1))
        command(signer, ["--verify", str(received_feed)], rejection=True)
        checks.append("tampered_feed_rejected")

        # Exercise the production RC postprocessor and composed preview feed too.
        # These URLs are metadata only: this probe never contacts or publishes to GitHub.
        publisher_feed = root / "publisher-appcast.xml"
        publisher_root = ET.fromstring(feed_bytes)
        publisher_item = publisher_root.find("./channel/item")
        publisher_item.find(sparkle("shortVersionString")).text = "2.0.0"
        ET.SubElement(publisher_item, sparkle("channel")).text = "rc"
        publisher_item.find("enclosure").set("url", "https://github.com/CharafChnioune/nativ/releases/download/v2.0.0rc1/Nativ-2.0.0rc1.zip")
        publisher_feed.write_bytes(ET.tostring(publisher_root, encoding="utf-8", xml_declaration=True))
        options = {"tool": signer}
        sign_feed(publisher_feed, **options)  # same auto-signing behavior as generate_appcast
        finalize_signed_appcast(publisher_feed, "v2.0.0rc1", "CharafChnioune/nativ", **options)
        verify_feed(publisher_feed, **options)
        final_publisher_bytes = publisher_feed.read_bytes()
        final_item = parse_item(final_publisher_bytes, "v2.0.0rc1", "CharafChnioune/nativ")
        checks.append("postprocessed_rc_feed_signature_verified")
        preview = root / "preview-appcast.xml"
        preview.write_bytes(preview_appcast([(version_info("v2.0.0rc1")[3], 2, final_item)]))
        sign_feed(preview, **options)
        verify_feed(preview, **options)
        final_preview_bytes = preview.read_bytes()
        checks.append("composed_preview_feed_signature_verified")
        for path, data in [(publisher_feed, final_publisher_bytes), (preview, final_preview_bytes)]:
            path.write_bytes(data.replace(b"2.0.0rc1", b"2.0.0rc2", 1))
            command(signer, ["--verify", str(path)], rejection=True)
        checks.append("tampered_publisher_and_preview_feeds_rejected")

        report = {"status": "passed", "timestamp_utc": datetime.now(timezone.utc).isoformat(),
                  "scope": "signed archive and signed XML over loopback; no application install, notarization or publication",
                  "sparkle_version": VERSION, "tools_archive_sha256": ARCHIVE_SHA256,
                  "keychain_account": ACCOUNT, "public_key": public_key, "checks": checks,
                  "archive_sha256": hashlib.sha256(archive_bytes).hexdigest(),
                  "feed_sha256": hashlib.sha256(feed_bytes).hexdigest(),
                  "private_key_exported": False}
        output.mkdir(parents=True)
        (output / archive.name).write_bytes(archive_bytes)
        (output / "appcast.xml").write_bytes(feed_bytes)
        (output / "publisher-appcast.xml").write_bytes(final_publisher_bytes)
        (output / "preview-appcast.xml").write_bytes(final_preview_bytes)
        (output / "report.json").write_text(json.dumps(report, indent=2) + "\n")
        return report


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    print(json.dumps(verify(args.output), indent=2))
