"""Real, weight-free parent death/cancellation tests for managed pip ownership."""
import fcntl
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import signal
import shlex
import shutil
import subprocess
import sys
import tempfile
import threading
import time
import unittest

OVERLAY=Path(__file__).resolve().parents[2]/'PythonDistribution/Overlay'
sys.path.insert(0,str(OVERLAY))
from nativ_generation.setup_command import run_setup_command

CHILD="import signal,time;signal.signal(signal.SIGTERM,signal.SIG_IGN);time.sleep(120)"
COMMAND="""import json,os,subprocess,sys,time
from pathlib import Path
child=subprocess.Popen([sys.executable,'-c',sys.argv[2]])
Path(sys.argv[1]).write_text(json.dumps([os.getpid(),child.pid]))
if sys.argv[3]=='stay':time.sleep(120)
"""
PARENT="""import fcntl,json,os,sys,threading
from nativ_generation.setup_command import run_setup_command
file=open(sys.argv[1],'a+b');fcntl.flock(file,fcntl.LOCK_EX)
run_setup_command(json.loads(sys.argv[2]),cancel=threading.Event(),compute_lease_fd=file.fileno())
"""

def live(pid):
    result=subprocess.run(['/bin/ps','-p',str(pid),'-o','stat='],capture_output=True,text=True)
    return bool(result.stdout.strip()) and not result.stdout.strip().startswith('Z')

def until(condition,timeout=6):
    end=time.monotonic()+timeout
    while time.monotonic()<end:
        if condition():return True
        time.sleep(.02)
    return False

class SetupProcessTests(unittest.TestCase):
    def command(self,path,mode='stay'):
        return [sys.executable,'-c',COMMAND,str(path),CHILD,mode]
    def test_normal_exit_cleans_build_child_before_return(self):
        with tempfile.TemporaryDirectory() as td:
            receipt=Path(td)/'pids'
            self.assertEqual(run_setup_command(self.command(receipt,'exit'),cancel=threading.Event()),0)
            self.assertTrue(all(not live(pid) for pid in json.loads(receipt.read_text())))
    def test_cancellation_waits_for_all_group_members(self):
        with tempfile.TemporaryDirectory() as td:
            receipt=Path(td)/'pids';cancel=threading.Event();errors=[]
            def run():
                try:run_setup_command(self.command(receipt),cancel=cancel)
                except BaseException as error:errors.append(error)
            thread=threading.Thread(target=run);thread.start()
            self.assertTrue(until(receipt.exists));pids=json.loads(receipt.read_text())
            cancel.set();thread.join(6)
            self.assertFalse(thread.is_alive());self.assertIsInstance(errors[0],InterruptedError)
            self.assertTrue(all(not live(pid) for pid in pids))
    def test_host_sigkill_retains_flock_until_owned_children_stop(self):
        with tempfile.TemporaryDirectory() as td:
            receipt=Path(td)/'pids';lock=Path(td)/'lease'
            env=dict(os.environ,PYTHONPATH=str(OVERLAY),PYTHONDONTWRITEBYTECODE='1')
            parent=subprocess.Popen([sys.executable,'-B','-c',PARENT,str(lock),json.dumps(self.command(receipt))],env=env)
            pids=[]
            try:
                self.assertTrue(until(receipt.exists));pids=json.loads(receipt.read_text())
                contender=lock.open('a+b')
                with self.assertRaises(BlockingIOError):fcntl.flock(contender,fcntl.LOCK_EX|fcntl.LOCK_NB)
                parent.kill();parent.wait()
                # If admission becomes available, every owned process must have
                # stopped already; test repeatedly across the death boundary.
                def released():
                    try:fcntl.flock(contender,fcntl.LOCK_EX|fcntl.LOCK_NB)
                    except BlockingIOError:return False
                    self.assertTrue(all(not live(pid) for pid in pids));return True
                self.assertTrue(until(released));contender.close()
            finally:
                if parent.poll() is None:parent.kill();parent.wait()
                for pid in pids:
                    if live(pid):os.kill(pid,signal.SIGKILL)
    def test_child_environment_does_not_poison_supervisor_python(self):
        self.assertEqual(run_setup_command([sys.executable,'-I','-c','pass'],cancel=threading.Event(),
            env={'PYTHONHOME':'/does/not/exist','PYTHONPATH':'/does/not/exist'}),0)
    def test_both_packaged_builders_run_guarded_setup_without_overlay_checkout(self):
        for kind in ('Music','Video'):
            with self.subTest(kind=kind),tempfile.TemporaryDirectory() as td:
                root=Path(td);folder=root/(kind+'Runtimes');folder.mkdir()
                source=OVERLAY.parent/(kind+'Runtimes')/'manage.py'
                spec=importlib.util.spec_from_file_location('fixture_'+kind,source)
                manager=importlib.util.module_from_spec(spec);spec.loader.exec_module(manager)
                manager.ROOT=folder
                (folder/'licenses').mkdir();(folder/'licenses/NOTICE').write_text('fixture')
                (folder/'lock').write_bytes(b'')
                prefix=root/'python';site=prefix/'lib/python3.12/site-packages'
                for name in ('nativ_generation','nativ_'+kind.lower()):
                    (site/name).mkdir(parents=True);(site/name/'__init__.py').write_text('')
                shutil.copy2(OVERLAY/'nativ_generation/setup_command.py',site/'nativ_generation/setup_command.py')
                (prefix/'bin').mkdir();launcher=prefix/'bin/python3'
                launcher.write_text('#!/bin/sh\nif [ "$1" = "-c" ]; then echo 3.12; exit 0; fi\nexec '+shlex.quote(sys.executable)+' -I -c "pass"\n')
                launcher.chmod(0o755)
                manifest={'id':'fixture','provider':'fixture','source':None,
                    'lock':{'path':'lock','sha256':hashlib.sha256(b'').hexdigest()}}
                with (root/'lockfile').open('a+b') as lease:
                    fcntl.flock(lease,fcntl.LOCK_EX)
                    destination=root/'candidate'
                    manager.build_runtime(manifest,destination,prefix,threading.Event(),lambda *a:None,
                        compute_lease_fd=lease.fileno())
                self.assertTrue((destination/'nativ-runtime.json').is_file())
                self.assertTrue((destination/'python/lib/python3.12/site-packages/nativ_generation/setup_command.py').is_file())

if __name__=='__main__':unittest.main()
