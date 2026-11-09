import fcntl,json,os,select,signal,subprocess,sys,tempfile,time,unittest
from pathlib import Path
OVERLAY=Path(__file__).resolve().parents[2]/'PythonDistribution/Overlay'
sys.path.insert(0,str(OVERLAY))
from nativ_generation.resources import ComputeAdmission

@unittest.skipUnless(os.name=='posix','Process groups require POSIX')
class GenerationProcessTests(unittest.TestCase):
    def test_parent_pipe_death_reaps_worker_and_retains_admission_until_then(self):
        with tempfile.TemporaryDirectory() as temp:
            root=Path(temp);package=root/'nativ_music';package.mkdir();(package/'__init__.py').write_text('')
            (package/'workers.py').write_text('import os,time,json\nprint(json.dumps({"pid":os.getpid()}),flush=True)\ntime.sleep(60)\n')
            admission=ComputeAdmission(root/'lease');lease=admission.try_acquire('test');read,write=os.pipe()
            env=dict(os.environ,PYTHONPATH=str(root)+os.pathsep+str(OVERLAY),PYTHONDONTWRITEBYTECODE='1')
            proc=subprocess.Popen([sys.executable,'-m','nativ_generation.worker_guardian','--parent-fd',str(read),'--module','nativ_music.workers'],stdout=subprocess.PIPE,stderr=subprocess.PIPE,env=env,start_new_session=True,pass_fds=(read,lease.file.fileno()))
            os.close(read)
            try:
                self.assertTrue(select.select([proc.stdout],[],[],5)[0]);worker=json.loads(proc.stdout.readline())['pid']
                # Simulate parent death: closing its duplicate does not explicitly unlock.
                lease.file.close();lease.file=None
                self.assertIsNone(admission.try_acquire('contender'))
                os.close(write);write=None
                self.assertEqual(proc.wait(5),-signal.SIGKILL)
                deadline=time.monotonic()+5
                while time.monotonic()<deadline:
                    try:os.kill(worker,0)
                    except ProcessLookupError:break
                    status=subprocess.run(['ps','-o','stat=','-p',str(worker)],capture_output=True,text=True).stdout.strip()
                    if not status or status.startswith('Z'):break
                    time.sleep(.02)
                else:self.fail('Model worker survived parent death')
                acquired=admission.try_acquire('after');self.assertIsNotNone(acquired);acquired.close()
            finally:
                if write is not None:os.close(write)
                if proc.poll() is None:os.killpg(proc.pid,signal.SIGKILL);proc.wait()
                proc.stdout.close();proc.stderr.close();lease.close()
    def test_guardian_reports_real_worker_exit_before_shutdown(self):
        with tempfile.TemporaryDirectory() as temp:
            root=Path(temp);package=root/'nativ_video';package.mkdir();(package/'__init__.py').write_text('');(package/'workers.py').write_text('raise SystemExit(7)\n')
            read,write=os.pipe();proc=subprocess.Popen([sys.executable,'-m','nativ_generation.worker_guardian','--parent-fd',str(read),'--module','nativ_video.workers','--','--runtime-id','fixture-runtime'],stdout=subprocess.PIPE,stderr=subprocess.PIPE,env=dict(os.environ,PYTHONPATH=str(root)+os.pathsep+str(OVERLAY)),start_new_session=True,pass_fds=(read,));os.close(read)
            try:
                self.assertTrue(select.select([proc.stdout],[],[],5)[0]);self.assertEqual(json.loads(proc.stdout.readline()),{'type':'worker_exit','code':7});self.assertIsNone(proc.poll())
            finally:os.close(write);proc.wait(5);proc.stdout.close();proc.stderr.close()

class GenerationProtocolBoundsTests(unittest.TestCase):
    def test_partial_handshake_line_cannot_extend_deadline(self):
        from nativ_generation.runtimes import WorkerSupervisor
        from nativ_generation.contracts import GenerationError
        import shlex
        with tempfile.TemporaryDirectory() as directory:
            prefix=Path(directory);(prefix/'bin').mkdir()
            program=prefix/'bin/python3'
            code='import sys,time;sys.stdout.write("{\\\"type\\\":");sys.stdout.flush();time.sleep(3)'
            program.write_text('#!/bin/sh\nunset PYTHONHOME\nexec '+shlex.quote(sys.executable)+' -c '+shlex.quote(code)+'\n');program.chmod(0o755)
            started=time.monotonic()
            with self.assertRaises(GenerationError) as failure:
                WorkerSupervisor.handshake(prefix,dict(id='fixture',worker={'module':'nativ_music.workers'}),timeout=.1)
            self.assertEqual(failure.exception.code,'worker_handshake_timeout')
            self.assertLess(time.monotonic()-started,2)
    def test_write_all_preserves_complete_encoded_request_on_partial_writes(self):
        import nativ_generation.runtimes as runtimes
        self.assertTrue(hasattr(runtimes,'write_all'),'Worker stdin requires complete writes')
        class Partial:
            def __init__(self):self.data=bytearray()
            def write(self,data):chunk=bytes(data[:3]);self.data.extend(chunk);return len(chunk)
        target=Partial();payload=json.dumps({'lyrics':'exact words\n','seed':42}).encode()+b'\n'
        runtimes.write_all(target,payload,timeout=1)
        self.assertEqual(bytes(target.data),payload)
    def test_developer_venv_child_keeps_its_base_standard_library(self):
        import venv
        from nativ_generation.runtimes import child_environment
        with tempfile.TemporaryDirectory() as directory:
            prefix=Path(directory)/'venv';venv.EnvBuilder(with_pip=False).create(prefix)
            result=subprocess.run([str(prefix/'bin/python3'),'-c','import encodings,sys;print(sys.prefix)'],
                cwd=prefix,env=child_environment(prefix),capture_output=True,text=True,timeout=5)
            self.assertEqual(result.returncode,0,result.stderr)
            self.assertEqual(Path(result.stdout.strip()).resolve(),prefix.resolve())
            # Library fallbacks must not find unpinned models in the user's Hugging Face cache.
            self.assertTrue(Path(child_environment(prefix)['HF_HOME']).is_relative_to(prefix))
