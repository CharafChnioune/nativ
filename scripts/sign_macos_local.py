#!/usr/bin/env python3
"""Ad-hoc sign a local fork build. This does not produce a distributable release."""
from __future__ import annotations
import pathlib
import plistlib
import subprocess
import sys
import tempfile

NAMESPACE = 'io.github.charafchnioune.nativ'
MACH_O = {b'\xfe\xed\xfa\xce', b'\xce\xfa\xed\xfe', b'\xfe\xed\xfa\xcf', b'\xcf\xfa\xed\xfe', b'\xca\xfe\xba\xbe', b'\xbe\xba\xfe\xca'}

def validate_app(app: pathlib.Path) -> None:
    with (app / 'Contents/Info.plist').open('rb') as stream:
        info = plistlib.load(stream)
    if info.get('CFBundleIdentifier') != NAMESPACE:
        raise ValueError('Local signing is restricted to this fork bundle identity')
    if not (app / 'Contents/MacOS/Nativ').is_file():
        raise ValueError('The local Nativ executable is missing')

def sign(app: pathlib.Path) -> None:
    app = app.resolve()
    validate_app(app)
    def run(args): subprocess.run(args, check=True, timeout=60)
    def codesign(path, extra=()):
        run(['/usr/bin/codesign', '--force', '--sign', '-', '--timestamp=none', *extra, str(path)])
    paths = sorted(app.rglob('*'), key=lambda path: len(path.parts), reverse=True)
    for path in paths:
        if path.is_symlink() or not path.is_file(): continue
        with path.open('rb') as stream: magic = stream.read(4)
        if magic in MACH_O: codesign(path)
    for path in paths:
        if path.is_dir() and not path.is_symlink() and path.suffix in {'.app', '.framework', '.xpc', '.appex'}:
            codesign(path)
    with tempfile.NamedTemporaryFile(suffix='.plist') as entitlements:
        entitlements.write(plistlib.dumps({'com.apple.security.device.audio-input': True}))
        entitlements.flush()
        codesign(app, ('--entitlements', entitlements.name))
    run(['/usr/bin/codesign', '--verify', '--deep', '--strict', str(app)])
    print('Verified local ad-hoc fork build. Privacy grants may need renewal after rebuilding; no signed update is available.')

if __name__ == '__main__':
    if len(sys.argv) != 2: raise SystemExit('Usage: sign_macos_local.py <Nativ.app>')
    sign(pathlib.Path(sys.argv[1]))
