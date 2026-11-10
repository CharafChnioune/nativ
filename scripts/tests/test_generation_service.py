import sys,tempfile,threading,time,unittest,wave,struct
from pathlib import Path
sys.path.insert(0,str(Path(__file__).resolve().parents[2]/'PythonDistribution/Overlay'))
from nativ_generation.contracts import ProviderResult,GenerationError,CancellationResult
from nativ_generation.service import GenerationService

class Fixture:
    calls=0; barrier=None; uncertain=False; reconcile_calls=0
    def normalize(self,request): return dict(request,seed=request.get('seed',42))
    def run(self,job,ctx):
        ctx.begin_dispatch(); Fixture.calls+=1
        if Fixture.uncertain: raise GenerationError('connection_lost','Unknown outcome',definitive=False)
        if Fixture.barrier:
            while not Fixture.barrier.wait(.01): ctx.check_cancelled()
        ctx.check_cancelled(); path=ctx.output_dir/'out.wav'
        with wave.open(str(path),'wb') as f: f.setparams((1,2,8000,0,'NONE',''));f.writeframes(struct.pack('<100h',*range(100)))
        return ProviderResult(path)
    def reconcile(self,job,ctx): Fixture.reconcile_calls+=1; raise GenerationError('pending','Not yet available',definitive=False)
    def cancel(self,job,ctx): return CancellationResult(False)
    def shutdown(self): pass

class GenerationServiceTests(unittest.TestCase):
    def setUp(self):
        Fixture.calls=0;Fixture.barrier=None;Fixture.uncertain=False;Fixture.reconcile_calls=0
        self.tmp=tempfile.TemporaryDirectory()
        self.profile={'id':'fixture','deployment':'local','modality':'music','provider':'fixture','defaults':{},'qualification':'experimental','runtime':None}
        self.s=GenerationService(Path(self.tmp.name),profiles=[self.profile],provider_factory=lambda *a:Fixture(),autostart=False)
        self.s.configure('fixture',{'enabled':True,'experimental_enabled':True,'license_accepted':True})
    def tearDown(self): self.s.close();self.tmp.cleanup()
    def wait_state(self,jid,states):
        end=time.monotonic()+3
        while time.monotonic()<end:
            job=self.s.repo.get_job(jid)
            if job['state'] in states: return job
            time.sleep(.01)
        self.fail(str(job))
    def test_acestep_is_disabled_as_non_mlx_runtime(self):
        reason=self.s.readiness(dict(self.profile,id='ace',provider='acestep'))['unavailable_reason']
        self.assertIn('MLX',reason)
    def test_runtime_with_another_builds_worker_code_asks_for_repair_before_submit(self):
        from unittest.mock import patch
        stale=type('Runtimes',(),{'ready':lambda self,pid:True,'outdated':lambda self,pid:True})()
        with patch.object(self.s,'runtimes',stale):
            ready=self.s.readiness(dict(self.profile,runtime='fixture-runtime'))
        self.assertEqual(ready['readiness'],'unavailable');self.assertIn('Repair',ready['unavailable_reason'])
    def test_submit_is_durable_and_duplicate_uses_frozen_defaults(self):
        j=self.s.submit('music',{'model':'fixture','prompt':'one'},'key')
        self.s.configure('fixture',{'enabled':False})
        self.assertEqual(self.s.submit('music',{'model':'fixture','prompt':'one'},'key')['job_id'],j['job_id'])
        with self.assertRaises(GenerationError):self.s.submit('music',{'model':'fixture','prompt':'two'},'key')
        self.assertEqual(Fixture.calls,0)
    def test_scheduler_publishes_one_generation(self):
        j=self.s.submit('music',{'model':'fixture','prompt':'one'},'key');self.s.start()
        self.assertEqual(self.wait_state(j['job_id'],{'succeeded'})['state'],'succeeded');self.assertEqual(Fixture.calls,1)
    def test_cancellation_holds_worker_until_terminated(self):
        Fixture.barrier=threading.Event();j=self.s.submit('music',{'model':'fixture','prompt':'one'},'key');self.s.start()
        self.wait_state(j['job_id'],{'running'});self.s.cancel(j['job_id'])
        self.assertEqual(self.wait_state(j['job_id'],{'cancelled'})['state'],'cancelled');self.assertIsNone(self.s.repo.get_job(j['job_id'])['asset_id'])
    def test_unknown_paid_submission_not_replayed_and_reserves_capacity(self):
        self.profile['deployment']='hosted';self.s.configure('fixture',{'account_id':'test','enabled':True})
        self.s.credentials=lambda p:'fixture-key';Fixture.uncertain=True
        j=self.s.submit('music',{'model':'fixture','prompt':'one','allow_remote':True},'key');self.s.start()
        self.assertEqual(self.wait_state(j['job_id'],{'submission_unknown'})['remote_reservation'],'reserved')
        self.s.submit('music',{'model':'fixture','prompt':'two','allow_remote':True},'two');time.sleep(.1)
        self.assertEqual(Fixture.calls,1)
    def test_configuration_cannot_inject_paths_or_secrets(self):
        for values in ({'model_path':'/tmp'},{'api_key':'secret'},{'enabled':'yes'}):
            with self.assertRaises(GenerationError):self.s.configure('fixture',values)
    def test_ambiguous_provider_503_preserves_reservation(self):
        self.profile['deployment']='hosted';self.s.credentials=lambda p:'fixture';self.s.configure('fixture',{'account_id':'test'})
        j=self.s.submit('music',{'model':'fixture','prompt':'one','allow_remote':True},'key')
        j=self.s.repo.begin_attempt(j['job_id']);self.s.repo.dispatch(j['job_id'],j['attempt_id'])
        self.s._failure(self.s.repo.get_job(j['job_id']),GenerationError('provider_rejected','HTTP 503',definitive=False,status=502))
        latest=self.s.repo.get_job(j['job_id']);self.assertEqual(latest['state'],'submission_unknown');self.assertEqual(latest['remote_reservation'],'reserved')
    def test_completed_remote_execution_with_failed_download_releases_reservation(self):
        class Completed(Fixture):
            def run(self,job,ctx):
                ctx.begin_dispatch();ctx.emit('writing_audio',provider_outcome='completed',private_url='must-not-persist')
                raise GenerationError('decode_failed','The result could not be decoded.',definitive=False)
        self.profile['deployment']='hosted';self.s.credentials=lambda p:'fixture';self.s.configure('fixture',{'account_id':'test'})
        self.s.factory=lambda *a:Completed()
        j=self.s.submit('music',{'model':'fixture','prompt':'one','allow_remote':True},'key');self.s.start()
        latest=self.wait_state(j['job_id'],{'failed'})
        self.assertEqual(latest['provider_outcome'],'completed');self.assertEqual(latest['remote_reservation'],'released')
        self.assertNotIn('must-not-persist',str(self.s.repo.events(j['job_id'])))
    def test_revoking_provider_before_dispatch_prevents_execution(self):
        j=self.s.submit('music',{'model':'fixture','prompt':'one'},'key');self.s.configure('fixture',{'enabled':False});self.s.start()
        self.wait_state(j['job_id'],{'failed'});self.assertEqual(Fixture.calls,0)
    def test_inactive_unknown_cancel_completes_observation_without_replay(self):
        self.profile['deployment']='hosted';self.s.credentials=lambda p:'fixture';self.s.configure('fixture',{'account_id':'test'})
        j=self.s.submit('music',{'model':'fixture','prompt':'one','allow_remote':True},'key');j=self.s.repo.begin_attempt(j['job_id']);self.s.repo.dispatch(j['job_id'],j['attempt_id'])
        self.s._failure(self.s.repo.get_job(j['job_id']),GenerationError('lost','Unknown',definitive=False))
        self.s.cancel(j['job_id']);latest=self.wait_state(j['job_id'],{'cancelled'})
        self.assertEqual(Fixture.calls,0);self.assertEqual(latest['remote_reservation'],'reserved')
    def test_prepare_stop_holds_queued_intent_and_rejects_new_submission(self):
        j=self.s.submit('music',{'model':'fixture','prompt':'one'},'key');state=self.s.prepare_stop()
        self.assertTrue(state['ready_to_stop']);self.assertEqual(self.s.repo.get_job(j['job_id'])['state'],'recovery_hold')
        with self.assertRaises(GenerationError):self.s.submit('music',{'model':'fixture','prompt':'two'},'two')
    def test_profile_revision_change_cannot_redispatch_held_intent(self):
        self.profile['profile_revision']='original'
        j=self.s.submit('music',{'model':'fixture','prompt':'one'},'key')
        self.s.repo.recover();self.profile['profile_revision']='changed'
        self.s.resume(j['job_id']);self.s.start();latest=self.wait_state(j['job_id'],{'failed'})
        self.assertEqual(latest['error']['code'],'profile_changed');self.assertEqual(Fixture.calls,0)
