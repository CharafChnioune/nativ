#!/usr/bin/env python3
"""Build/verify the pinned helper and copy only the complete runtime into the app."""
from __future__ import annotations
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[1]

def valid_runtime(runtime: Path, manifest: dict) -> bool:
    try:
        evidence = json.loads((runtime / 'build-evidence.json').read_text())
        helper = runtime / 'bin/llama-server'
        return (evidence['runtimeCommit'] == manifest['runtime']['commit']
                and evidence['patches'] == manifest['runtime']['patches']
                and hashlib.sha256(helper.read_bytes()).hexdigest() == evidence['sha256']
                and json.loads((runtime / 'runtime-manifest.json').read_text()) == manifest)
    except (OSError, ValueError, KeyError):
        return False

def main():
    if len(sys.argv) != 2:
        raise SystemExit('Usage: install_lfm_realtime_runtime.py <app-resources-directory>')
    manifest = json.loads((ROOT / 'ThirdParty/LFMRealtime/runtime-manifest.json').read_text())
    runtime = ROOT / 'build/lfm-realtime/runtime'
    if not valid_runtime(runtime, manifest):
        subprocess.run([sys.executable, str(ROOT / 'scripts/build_lfm_realtime_runtime.py')], check=True, timeout=1800)
    if not valid_runtime(runtime, manifest):
        raise SystemExit('The complete pinned translation helper could not be verified')
    destination = Path(sys.argv[1]) / 'LFMRealtime'
    destination.parent.mkdir(parents=True, exist_ok=True)
    # Xcode owns this output directory; do not touch installed applications.
    staged = destination.with_name('LFMRealtime.staging')
    if staged.exists(): shutil.rmtree(staged)
    shutil.copytree(runtime, staged)
    identity = os.environ.get('EXPANDED_CODE_SIGN_IDENTITY') or os.environ.get('CODE_SIGN_IDENTITY') or '-'
    command = ['/usr/bin/codesign', '--force', '--sign', identity, '--timestamp=none']
    if identity != '-': command += ['--options', 'runtime']
    subprocess.run(command + [str(staged / 'bin/llama-server')], check=True, timeout=60)
    if destination.exists(): shutil.rmtree(destination)
    staged.replace(destination)
    print('Installed pinned LFM3 runtime (no model weights bundled).')

if __name__ == '__main__': main()
