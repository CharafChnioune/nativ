from pathlib import Path
import os
import shlex
import sys
import tempfile
from threading import Event
import unittest

ROOT=Path(__file__).resolve().parents[2]
OVERLAY=ROOT/'PythonDistribution/Overlay'
sys.path.insert(0,str(OVERLAY))
from nativ_generation.contracts import ProviderContext,ProviderServices,GenerationError
from nativ_generation.remote_process import RemoteExecutionProvider
from nativ_generation.runtimes import WorkerSupervisor
from nativ_music.catalog import profiles
from nativ_music.providers import build_provider


class GenerationProcessTrustTests(unittest.TestCase):
    def malicious(self,root):
        package=root/'nativ_generation';package.mkdir();(package/'__init__.py').write_text('')
        marker=root/'untrusted-credential-observed'
        (package/'worker_guardian.py').write_text('import json,sys\nfrom pathlib import Path\nprint(json.dumps({"type":"handshake","protocol":1,"worker":"nativ-remote"}),flush=True)\nvalue=json.loads(sys.stdin.readline())\nPath('+repr(str(marker))+').write_text("untrusted helper read credential envelope")\nprint(json.dumps({"type":"worker_exit","code":0}),flush=True)\n')
        return marker

    def test_remote_helper_cannot_load_cwd_package_or_receive_credential(self):
        with tempfile.TemporaryDirectory() as directory:
            root=Path(directory);marker=self.malicious(root)
            scenarios=[('lyria-3.5-hosted',None,{},'configuration_required'),
                ('minimax-music3-cloud','fixture-only-key',{'endpoint':'https://invalid-provider.example'},'invalid_configuration')]
            for identifier,key,configuration,code in scenarios:
                with self.subTest(profile=identifier):
                    profile=next(value for value in profiles() if value['id']==identifier)
                    services=ProviderServices(configuration={identifier:configuration},credentials=lambda _,key=key:key)
                    accepted=build_provider(profile,services).normalize(dict(model=identifier,prompt='fixture',instrumental=True,allow_remote=True))
                    provider=RemoteExecutionProvider(profile,services)
                    dispatched=[]
                    context=ProviderContext(output_dir=root,cancellation=Event(),emit=lambda *args:None,dispatch=lambda:dispatched.append(True),operation=lambda *args:None)
                    old=Path.cwd();os.chdir(root)
                    try:
                        with self.assertRaises(GenerationError) as failure:provider.run(dict(profile=profile,request=accepted),context)
                    finally:os.chdir(old)
                    self.assertEqual(failure.exception.code,code)
                    self.assertFalse(marker.exists(),'An untrusted current-directory helper consumed the credential envelope')
                    self.assertEqual(dispatched,[])

    def test_local_handshake_uses_trusted_prefix_instead_of_cwd(self):
        with tempfile.TemporaryDirectory() as directory:
            root=Path(directory);malicious=root/'malicious';malicious.mkdir()
            package=malicious/'nativ_music';package.mkdir();(package/'__init__.py').write_text('')
            marker=root/'untrusted-local-worker'
            runtime='minimax-music3-mlx-0.6.4'
            (package/'workers.py').write_text('import json,sys\nfrom pathlib import Path\nPath('+repr(str(marker))+').write_text("untrusted")\nprint(json.dumps({"type":"handshake","protocol":1,"runtime_id":'+repr(runtime)+'}),flush=True)\nsys.stdin.readline()\n')
            prefix=root/'trusted-python';(prefix/'bin').mkdir(parents=True)
            interpreter=prefix/'bin/python3'
            interpreter.write_text('#!/bin/sh\nunset PYTHONHOME\nexport PYTHONPATH='+shlex.quote(str(OVERLAY))+'\nexec '+shlex.quote(sys.executable)+' "$@"\n');interpreter.chmod(0o755)
            manifest=dict(id=runtime,worker=dict(module='nativ_music.workers',args=['--runtime-id',runtime]))
            old=Path.cwd();os.chdir(malicious)
            try:WorkerSupervisor.handshake(prefix,manifest)
            finally:os.chdir(old)
            self.assertFalse(marker.exists(),'A worker outside the prepared prefix shadowed its handshake')


if __name__=='__main__':unittest.main()
