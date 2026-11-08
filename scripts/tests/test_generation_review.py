"""Independent regressions for failed construction and server-stop admission."""
import sys
import tempfile
import threading
import time
from pathlib import Path
from unittest import TestCase,main
from unittest.mock import Mock,patch
sys.path.insert(0,str(Path(__file__).resolve().parents[2]/'PythonDistribution'/'Overlay'))
from nativ_generation.repository import GenerationRepository
from nativ_generation.service import GenerationService
from nativ_generation.contracts import GenerationError

class GenerationIndependentReviewTests(TestCase):
    def setUp(self):self.retained_errors=[]
    def capture(self,call):
        try:call()
        except Exception as error:self.retained_errors.append(error)
        else:self.fail('The injected initialization failure must propagate')
    def reopen(self,root):
        repository=GenerationRepository(root)
        try:self.assertTrue(repository.store_id)
        finally:repository.close()
    def test_sqlite_connect_failure_does_not_retain_scheduler_lock_in_traceback(self):
        with tempfile.TemporaryDirectory() as td:
            root=Path(td)
            with patch('nativ_generation.repository.sqlite3.connect',side_effect=OSError('fixture connection failure')):
                self.capture(lambda:GenerationRepository(root))
            self.reopen(root)
    def test_pragma_failure_closes_database_and_releases_scheduler_lock(self):
        connection=Mock();connection.execute.side_effect=OSError('fixture pragma failure')
        with tempfile.TemporaryDirectory() as td:
            root=Path(td)
            with patch('nativ_generation.repository.sqlite3.connect',return_value=connection):
                self.capture(lambda:GenerationRepository(root))
            connection.close.assert_called_once();self.reopen(root)
    def test_ddl_failure_closes_database_and_releases_scheduler_lock(self):
        connection=Mock();connection.execute.return_value.fetchone.return_value=[0]
        connection.executescript.side_effect=OSError('fixture DDL failure')
        with tempfile.TemporaryDirectory() as td:
            root=Path(td)
            with patch('nativ_generation.repository.sqlite3.connect',return_value=connection):
                self.capture(lambda:GenerationRepository(root))
            connection.close.assert_called_once();self.reopen(root)
    def test_asset_recovery_failure_releases_canonical_repository(self):
        with tempfile.TemporaryDirectory() as td:
            root=Path(td)
            with patch('nativ_generation.service.AssetStore.recover',side_effect=OSError('fixture recovery failure')):
                self.capture(lambda:GenerationService(root,profiles=[],autostart=False))
            self.reopen(root)
    def test_stop_fences_a_submit_already_inside_normalization(self):
        entered=threading.Event();release=threading.Event();stop_started=threading.Event();result=[];errors=[]
        class Provider:
            def normalize(self,request):entered.set();release.wait(2);return dict(request)
        profile={'id':'fixture','modality':'music','provider':'fixture','deployment':'local','qualification':'qualified','runtime':None,'defaults':{}}
        with tempfile.TemporaryDirectory() as td:
            service=GenerationService(Path(td),profiles=[profile],provider_factory=lambda *a:Provider(),autostart=False)
            service.configure('fixture',{'enabled':True,'license_accepted':True})
            def submit():
                try:result.append(service.submit('music',{'model':'fixture','prompt':'one'},'same-intent'))
                except GenerationError as error:errors.append(error)
            def stop():stop_started.set();service.prepare_stop()
            sender=threading.Thread(target=submit);stopper=threading.Thread(target=stop)
            try:
                sender.start();self.assertTrue(entered.wait(1));stopper.start();self.assertTrue(stop_started.wait(1))
                # Give stop its snapshot opportunity while acceptance is suspended.
                service._stopping.wait(.05);release.set();sender.join(2);stopper.join(2)
                self.assertFalse(sender.is_alive());self.assertFalse(stopper.is_alive())
                self.assertTrue(service.server_state()['stopping'])
                if result:self.assertEqual(service.repo.get_job(result[0]['job_id'])['state'],'recovery_hold')
                else:self.assertEqual(errors[0].code,'server_stopping')
                with self.assertRaises(GenerationError):service.submit('music',{'model':'fixture','prompt':'later'},'new-intent')
            finally:
                release.set();sender.join(2)
                if stopper.ident is not None:stopper.join(2)
                service.close()

    def test_stop_cancels_reconciliation_admitted_before_scheduler_join_finishes(self):
        class Provider:
            def normalize(self,request):return dict(request)
        profile={'id':'fixture','modality':'music','provider':'fixture','deployment':'local','qualification':'qualified','runtime':None,'defaults':{}}
        with tempfile.TemporaryDirectory() as td:
            service=GenerationService(Path(td),profiles=[profile],provider_factory=lambda *a:Provider(),autostart=False)
            service.configure('fixture',{'enabled':True,'license_accepted':True})
            job=service.submit('music',{'model':'fixture','prompt':'one'},'intent')
            job=service.repo.begin_attempt(job['job_id']);service.repo.dispatch(job['job_id'],job['attempt_id'])
            service.repo.update_attempt(job['job_id'],job['attempt_id'],state='retrieval_pending')
            cancelled=threading.Event();scheduler=Mock()
            # Model an already-entered scheduler iteration starting its existing
            # operation reconciliation just before its thread finishes stopping.
            scheduler.join.side_effect=lambda:service._active.update({job['job_id']:{'thread':Mock(),'cancel':cancelled,'lane':'music'}})
            service._scheduler=scheduler
            try:
                service.prepare_stop();self.assertTrue(cancelled.is_set())
            finally:
                service._active.clear();service._scheduler=None;service.close()

if __name__=='__main__':main()
