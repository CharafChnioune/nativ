"""Owned setup subprocesses, including pip build descendants.

The supervisor holds the inherited compute lock independently of the host. A
separate, live group anchor prevents process-group ID reuse until cleanup. Host
pipe EOF, cancellation and normal command completion all terminate that group
before the supervisor closes its lock descriptor. No shell or ambient imports.
"""
from __future__ import annotations
import json
import os
from pathlib import Path
import selectors
import signal
import subprocess
import sys
import time


def run_setup_command(command, *, cancel, env=None, compute_lease_fd=None):
    if cancel.is_set():
        raise InterruptedError('Runtime build cancelled')
    payload=json.dumps({'command':list(map(str,command)), 'env':env}).encode()
    if len(payload)>1024*1024:
        raise ValueError('Setup command exceeds protocol limit')
    read_fd,write_fd=os.pipe()
    inherited=(read_fd,) if compute_lease_fd is None else (read_fd,compute_lease_fd)
    process=None
    cancelled=False
    try:
        process=subprocess.Popen([sys.executable,'-I','-B',str(Path(__file__).resolve()),
            '--supervise',str(read_fd),str(compute_lease_fd if compute_lease_fd is not None else -1)],
            stdin=subprocess.PIPE,stdout=subprocess.PIPE,stderr=subprocess.DEVNULL,
            pass_fds=inherited,start_new_session=True)
        os.close(read_fd);read_fd=-1
        process.stdin.write(payload);process.stdin.close();process.stdin=None
        while process.poll() is None:
            if cancel.wait(.05):
                cancelled=True
                if write_fd!=-1:os.close(write_fd);write_fd=-1
        result=process.stdout.read(4097)
        if cancelled:raise InterruptedError('Runtime build cancelled')
        if process.returncode or len(result)>4096:
            raise RuntimeError('Setup process supervisor failed')
        return int(json.loads(result)['returncode'])
    finally:
        if read_fd!=-1:os.close(read_fd)
        if write_fd!=-1:os.close(write_fd)
        if process is not None:
            if process.stdin is not None:
                try:process.stdin.close()
                except OSError:pass
            # EOF asks the supervisor to kill/reap its entire owned group. Never
            # abandon it on observer exceptions and release admission early.
            process.wait()
            if process.stdout is not None:process.stdout.close()


def _anchor(payload):
    process=subprocess.Popen(payload['command'],env=payload['env'],stdin=subprocess.DEVNULL,
        stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL,close_fds=True)
    code=process.wait()
    print(json.dumps({'returncode':code}),flush=True)
    # Remain the live session/group leader after pip exits. The supervisor owns
    # termination, including descendants which outlive the command itself.
    while True:signal.pause()


def _group_running(group):
    # A reparented zombie has already released its compute resources; waiting for
    # launchd/init to reap it must not prevent admission indefinitely.
    try:listing=subprocess.check_output(['/bin/ps','-axo','pgid=,stat='],text=True)
    except (OSError,subprocess.SubprocessError):
        # Fail closed: a failed process inventory cannot prove resource release.
        time.sleep(.1)
        return True
    return any(int(parts[0])==group and not parts[1].startswith('Z')
        for line in listing.splitlines() if len(parts:=line.split())>=2)


def _supervise(payload,parent_fd,lease_fd):
    if lease_fd>=0:os.fstat(lease_fd)
    stopped=False
    def stop(*_):
        nonlocal stopped
        stopped=True
    for sig in (signal.SIGTERM,signal.SIGINT,signal.SIGHUP):signal.signal(sig,stop)
    anchor=None
    selector=selectors.DefaultSelector()
    try:
        selector.register(parent_fd,selectors.EVENT_READ,'parent')
        anchor=subprocess.Popen([sys.executable,'-I','-B',str(Path(__file__).resolve()),'--anchor'],
            stdin=subprocess.PIPE,stdout=subprocess.PIPE,stderr=subprocess.DEVNULL,
            close_fds=True,start_new_session=True)
        anchor.stdin.write(json.dumps(payload).encode());anchor.stdin.close();anchor.stdin=None
        selector.register(anchor.stdout,selectors.EVENT_READ,'result')
        result=None
        while not stopped and result is None:
            for key,_ in selector.select(.05):
                if key.data=='parent':
                    if not os.read(parent_fd,64):stopped=True
                else:
                    line=anchor.stdout.readline(4097)
                    if not line:raise RuntimeError('Setup anchor exited before its result')
                    result=json.loads(line)
        return result or {'returncode':-signal.SIGTERM}
    finally:
        if anchor is not None:
            # Keep the supervisor (and its lease FD) outside the killed group.
            try:os.killpg(anchor.pid,signal.SIGKILL)
            except ProcessLookupError:pass
            # Keep the anchor unreaped until no live group member remains. Its
            # reserved PID prevents accidentally signalling a reused group ID.
            while _group_running(anchor.pid):
                try:os.killpg(anchor.pid,signal.SIGKILL)
                except ProcessLookupError:pass
                time.sleep(.02)
            anchor.wait()
            anchor.stdout.close()
        selector.close()


if __name__=='__main__':
    data=sys.stdin.buffer.read(1024*1024+1)
    if len(data)>1024*1024:raise SystemExit(2)
    payload=json.loads(data)
    if sys.argv[1]=='--anchor':_anchor(payload)
    elif sys.argv[1]=='--supervise':
        result=_supervise(payload,int(sys.argv[2]),int(sys.argv[3]))
        print(json.dumps(result),flush=True)
    else:raise SystemExit(2)
