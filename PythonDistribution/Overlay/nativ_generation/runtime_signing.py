"""Prepare only a private interpreter copy for user-installed native wheels.

Release Python is hardened and Team-signed. Those properties are appropriate
inside the application, but library validation rejects native wheels installed
later without that Team identity. The managed copy receives a local ad-hoc
signature before pip runs. The application and its interpreter remain intact.
"""
from __future__ import annotations

from pathlib import Path
import subprocess
import sys

MACH_O_MAGICS = {b'\xfe\xed\xfa\xce', b'\xce\xfa\xed\xfe', b'\xfe\xed\xfa\xcf',
                 b'\xcf\xfa\xed\xfe', b'\xca\xfe\xba\xbe', b'\xbe\xba\xfe\xca',
                 b'\xca\xfe\xba\xbf', b'\xbf\xba\xfe\xca'}


def prepare_interpreter(install_root, source_prefix, cancel):
    """Remove hardened library validation from a confined copied executable.

    Internal python3 -> python3.12 links are accepted; escaping links, overlapping
    source/staging trees and shared hardlinks are rejected before any mutation.
    Portable script fixtures and non-macOS hosts do not exercise signing.
    """
    if cancel.is_set():
        raise InterruptedError('Runtime build cancelled')
    stage = Path(install_root)
    source = Path(source_prefix).resolve(strict=True)
    if stage.is_symlink() or not stage.is_dir():
        raise ValueError('Runtime signing requires a private staging directory')
    stage = stage.resolve(strict=True)
    if stage == source or stage.is_relative_to(source) or source.is_relative_to(stage):
        raise ValueError('Runtime signing must not overlap the source Python prefix')
    prefix = stage / 'python'
    if prefix.is_symlink() or not prefix.is_dir():
        raise ValueError('Managed Python prefix must be a private directory')
    executable = (prefix / 'bin/python3').resolve(strict=True)
    if not executable.is_relative_to(prefix) or not executable.is_file():
        raise ValueError('Managed Python interpreter escapes its private prefix')
    if executable.stat().st_nlink != 1:
        raise ValueError('Managed Python interpreter must not share a hardlink')
    with executable.open('rb') as handle:
        native = handle.read(4) in MACH_O_MAGICS
    if sys.platform != 'darwin' or not native:
        return
    # Explicit options=0 avoids retaining the source executable's runtime flag.
    # No identity/keychain access, entitlements or global policy change is needed.
    for command in (
        ['/usr/bin/codesign', '--force', '--sign', '-', '--options', '0',
         '--timestamp=none', str(executable)],
        ['/usr/bin/codesign', '--verify', '--strict', str(executable)],
    ):
        if cancel.is_set():
            raise InterruptedError('Runtime build cancelled')
        result = subprocess.run(command, stdin=subprocess.DEVNULL,
                                stdout=subprocess.DEVNULL, stderr=subprocess.PIPE,
                                timeout=30, check=False)
        if result.returncode:
            raise RuntimeError('Managed Python local signature preparation failed')
