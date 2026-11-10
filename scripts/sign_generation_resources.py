#!/usr/bin/env python3
"""Trusted signing-side codec receipt refresh. Never execute bundled code."""
from __future__ import annotations
import argparse
import hashlib
import json
import os
from pathlib import Path
import plistlib
import sys

sys.path.insert(0, str(Path(__file__).resolve().parent))
from fork_release import NAMESPACE, validate_bundle_resources


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def receipt_path(app):
    return app / 'Contents/Frameworks/NativServerKit.framework/Resources/mlx-vlm-server/CodecRuntime/managed/receipt.json'


def prepare(app):
    app = Path(app).resolve(strict=True)
    with (app / 'Contents/Info.plist').open('rb') as stream:
        identity = plistlib.load(stream).get('CFBundleIdentifier')
    # The general release signer also supports unrelated app fixtures/clients.
    # Every actual fork app must pass the complete, static media-resource gate.
    if identity != NAMESPACE:
        return {'app': str(app), 'unrelated_bundle': True}
    validate_bundle_resources(app)
    receipt = receipt_path(app)
    return {'app': str(app), 'receipt_sha256': digest(receipt),
            'receipt': json.loads(receipt.read_text())}


def refresh(app, snapshot):
    app = Path(app).resolve(strict=True)
    if snapshot.get('app') != str(app):
        raise ValueError('Signing receipt snapshot belongs to another app')
    if snapshot.get('unrelated_bundle'):
        with (app / 'Contents/Info.plist').open('rb') as stream:
            if plistlib.load(stream).get('CFBundleIdentifier') == NAMESPACE:
                raise ValueError('Fork identity changed during signing')
        return
    receipt = receipt_path(app)
    if not receipt.resolve(strict=True).is_relative_to(app) or receipt.is_symlink():
        raise ValueError('Signing receipt escaped the app')
    if digest(receipt) != snapshot['receipt_sha256']:
        raise ValueError('Codec receipt changed after pre-sign verification')
    record = snapshot['receipt']
    # Preserve the original build provenance across any number of re-signings.
    record.setdefault('build_files', dict(record['files']))
    for name in ('ffmpeg', 'ffprobe'):
        binary = receipt.parent / 'bin' / name
        if binary.is_symlink() or not binary.resolve(strict=True).is_relative_to(app):
            raise ValueError('Signed codec escaped the app')
        record['files']['bin/' + name] = digest(binary)
    record['post_signing_receipt'] = True
    temporary = receipt.with_suffix('.json.signing-partial')
    try:
        descriptor = os.open(temporary, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
        with os.fdopen(descriptor, 'w') as stream:
            json.dump(record, stream, indent=2); stream.write('\n')
            stream.flush(); os.fsync(stream.fileno())
        temporary.replace(receipt)
    finally:
        temporary.unlink(missing_ok=True)
    validate_bundle_resources(app)  # static, no candidate interpreter execution


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('action', choices=('prepare', 'refresh'))
    parser.add_argument('app', type=Path)
    parser.add_argument('snapshot', type=Path)
    args = parser.parse_args()
    if args.action == 'prepare':
        snapshot = prepare(args.app)
        args.snapshot.write_text(json.dumps(snapshot))
        args.snapshot.chmod(0o600)
    else:
        refresh(args.app, json.loads(args.snapshot.read_text()))


if __name__ == '__main__':
    main()
