#!/usr/bin/env python3
"""Sign final feed bytes with Sparkle 2.9.4; private CI material travels over stdin only."""
from __future__ import annotations

import argparse
import os
from pathlib import Path
import subprocess
import tempfile
import xml.etree.ElementTree as ET

from sparkle_setup import ACCOUNT, DEFAULT_TOOLS

SIGNATURE_MARKER = b"<!-- sparkle-signatures:"


def signature_operation(path, *, verify=False, account=ACCOUNT, private_key_file=None, tool=None):
    tool = Path(tool or os.environ.get("SPARKLE_SIGN_UPDATE", DEFAULT_TOOLS / "sign_update"))
    if not tool.is_file() or not os.access(tool, os.X_OK):
        raise ValueError("Verified Sparkle sign_update was not prepared before signing")
    secret = os.environ.get("SPARKLE_PRIVATE_KEY", "")
    if secret and private_key_file:
        raise ValueError("Choose one Sparkle signing credential source")
    command = [str(tool)]
    if secret:
        command += ["--ed-key-file", "-"]
    elif private_key_file:
        command += ["--ed-key-file", str(private_key_file)]
    else:
        command += ["--account", account]
    command += ["--verify" if verify else "-p", str(path)]
    # Never expose tool output (which can contain diagnostics about malformed keys),
    # secret command arguments, or temporary private-key files.
    result = subprocess.run(command, input=secret + "\n" if secret else None,
                            text=True, capture_output=True, timeout=60)
    if result.returncode:
        raise ValueError("Sparkle feed signature verification failed" if verify else "Sparkle feed signing failed")
    if SIGNATURE_MARKER not in Path(path).read_bytes():
        raise ValueError("Sparkle feed-level signature is missing")


def verify_feed(path, **options):
    if SIGNATURE_MARKER not in Path(path).read_bytes():
        raise ValueError("Unsigned feed rejected")
    signature_operation(path, verify=True, **options)


def verify_feed_bytes(data, **options):
    with tempfile.TemporaryDirectory(prefix="nativ-verify-feed-") as directory:
        path = Path(directory) / "appcast.xml"
        path.write_bytes(data)
        verify_feed(path, **options)


def sign_feed(path, **options):
    signature_operation(path, **options)
    verify_feed(path, **options)


def finalize_signed_appcast(path, tag, repository, **options):
    from macos_release import atomic_write, finalize_appcast
    original = Path(path).read_bytes()
    with tempfile.TemporaryDirectory(prefix="nativ-final-feed-") as directory:
        candidate = Path(directory) / "appcast.xml"
        candidate.write_bytes(original)
        if SIGNATURE_MARKER in original:
            # generate_appcast signs automatically when SURequireSignedFeed is set.
            # Authenticate those bytes before deliberately replacing that signature.
            verify_feed(candidate, **options)
            candidate.write_bytes(ET.tostring(ET.fromstring(original), encoding="utf-8", xml_declaration=True))
        finalize_appcast(candidate, tag, repository)
        sign_feed(candidate, **options)
        # The original path changes only after the FINAL bytes were signed and verified.
        atomic_write(path, candidate.read_bytes())


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("command", choices=["finalize", "sign", "verify"])
    parser.add_argument("path", type=Path)
    parser.add_argument("--tag")
    parser.add_argument("--repository")
    parser.add_argument("--account", default=ACCOUNT)
    parser.add_argument("--private-key", type=Path)
    args = parser.parse_args()
    options = {"account": args.account, "private_key_file": args.private_key}
    if args.command == "finalize":
        if not args.tag or args.repository != "CharafChnioune/nativ":
            parser.error("finalize requires a fork tag and --repository CharafChnioune/nativ")
        finalize_signed_appcast(args.path, args.tag, args.repository, **options)
    elif args.command == "sign":
        sign_feed(args.path, **options)
    else:
        verify_feed(args.path, **options)


if __name__ == "__main__":
    main()
