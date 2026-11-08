#!/usr/bin/env python3
"""Configure this fork's public Sparkle key; keep its private key in Keychain."""
from __future__ import annotations

import argparse
import base64
import hashlib
import json
import os
from pathlib import Path
import re
import subprocess
import tempfile
import urllib.request
import zipfile

ROOT = Path(__file__).resolve().parents[1]
ACCOUNT = "io.github.charafchnioune.nativ"
SERVICE = "https://sparkle-project.org"
VERSION = "2.9.4"
ARCHIVE_SHA256 = "cb6fdbdc8884f15d62a616e79face92b08322410fd2d425edc6596ccbf4ba3b0"
ARCHIVE_URL = f"https://github.com/sparkle-project/Sparkle/releases/download/{VERSION}/Sparkle-for-Swift-Package-Manager.zip"
DEFAULT_ARCHIVE = ROOT / "build/release-review-tools/sparkle.zip"
DEFAULT_TOOLS = ROOT / "build/release-review-tools/verified/bin"
DEFAULT_CONFIG = ROOT / "Configuration/Fork.xcconfig"
UPSTREAM_KEY = "A8x4wdNekd1aoWpU8bVdsNdOFzuua8nC1mfLCwGDSPk="
ASSIGNMENT = re.compile(r"^NATIV_SPARKLE_PUBLIC_KEY[ \t]*=[ \t]*([^\r\n]*)$", re.MULTILINE)


def validate_public_key(key):
    try:
        valid = key != UPSTREAM_KEY and len(base64.b64decode(key, validate=True)) == 32
    except (ValueError, TypeError):
        valid = False
    if not valid:
        raise ValueError("A valid, non-upstream 32-byte Sparkle public key is required")
    return key


def read_public_key(config=DEFAULT_CONFIG):
    assignments = ASSIGNMENT.findall(Path(config).read_text())
    if len(assignments) != 1:
        raise ValueError("Exactly one public key assignment is required in Fork.xcconfig")
    key = assignments[0].strip()
    return validate_public_key(key) if key else ""


def atomic_write(path, data, mode):
    path = Path(path)
    path.parent.mkdir(parents=True, exist_ok=True)
    descriptor, temporary = tempfile.mkstemp(prefix=".sparkle-", dir=path.parent)
    try:
        with os.fdopen(descriptor, "wb") as handle:
            handle.write(data)
        os.chmod(temporary, mode)
        os.replace(temporary, path)
    finally:
        Path(temporary).unlink(missing_ok=True)


def verified_tools(archive=DEFAULT_ARCHIVE, directory=DEFAULT_TOOLS, prepare=False):
    """Authenticate the official archive and exact executed binaries before key access."""
    archive, directory = Path(archive), Path(directory)
    if not archive.is_file():
        if not prepare:
            raise ValueError("Sparkle tools are missing; run once with --prepare-tools")
        with urllib.request.urlopen(ARCHIVE_URL, timeout=60) as response:
            data = response.read(50 * 1024 * 1024 + 1)
        if hashlib.sha256(data).hexdigest() != ARCHIVE_SHA256:
            raise ValueError("Downloaded Sparkle archive checksum mismatch")
        atomic_write(archive, data, 0o644)
    if hashlib.sha256(archive.read_bytes()).hexdigest() != ARCHIVE_SHA256:
        raise ValueError("Sparkle archive checksum mismatch")
    with zipfile.ZipFile(archive) as package:
        for name in ("generate_keys", "sign_update"):
            expected = package.read("bin/" + name)
            destination = directory / name
            if not destination.is_file() and prepare:
                atomic_write(destination, expected, 0o755)
            if (destination.is_symlink() or not destination.is_file()
                    or destination.read_bytes() != expected or not os.access(destination, os.X_OK)):
                raise ValueError("Sparkle tool does not match the verified archive: " + name)
    return directory


def configure(config, generate_keys, initialize=False, run=subprocess.run):
    config = Path(config)
    existing = read_public_key(config)
    command = [str(generate_keys), "--account", ACCOUNT]
    # No export, import, password display or secret environment is used here.
    result = run(command + ["-p"], capture_output=True, text=True, timeout=60)
    created = False
    if result.returncode:
        if existing:
            raise ValueError("Public key already configured; restore access to its original Keychain key. No replacement was created")
        if not initialize:
            raise ValueError("No accessible Sparkle key; use --initialize to explicitly create the fork's Keychain key")
        status = run(["/usr/bin/security", "find-generic-password", "-s", SERVICE, "-a", ACCOUNT],
                     capture_output=True, text=True, timeout=60)
        if status.returncode != 44:  # errSecItemNotFound only; denial is never absence.
            raise ValueError("Keychain access failed or an existing item is unreadable; no key was created")
        creation = run(command, capture_output=True, text=True, timeout=60)
        if creation.returncode:
            raise ValueError("Sparkle Keychain initialization failed; inspect Keychain access locally")
        created = True
        result = run(command + ["-p"], capture_output=True, text=True, timeout=60)
        if result.returncode:
            raise ValueError("The newly initialized public key could not be read")
    public_key = validate_public_key(result.stdout.strip())
    if existing and existing != public_key:
        raise ValueError("Configured public key does not match the existing Keychain account; no rotation performed")
    if not existing:
        content = ASSIGNMENT.sub(lambda _: "NATIV_SPARKLE_PUBLIC_KEY = " + public_key, config.read_text())
        atomic_write(config, content.encode(), config.stat().st_mode & 0o777)
    return {"account": ACCOUNT, "public_key": public_key, "created": created, "changed": not bool(existing),
            "private_key_storage": "macOS Keychain", "sparkle_version": VERSION}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--initialize", action="store_true", help="Create only if both Keychain account and public config are empty")
    parser.add_argument("--prepare-tools", action="store_true", help="Download checksum-pinned tools if absent")
    args = parser.parse_args()
    directory = verified_tools(prepare=args.prepare_tools)
    print(json.dumps(configure(DEFAULT_CONFIG, directory / "generate_keys", args.initialize), indent=2))


if __name__ == "__main__":
    main()
