import json, math, struct, sys, tempfile, threading, unittest, wave
from pathlib import Path
sys.path.insert(0,str(Path(__file__).resolve().parents[2]/'PythonDistribution/Overlay'))
from nativ_generation.repository import GenerationRepository
from nativ_generation.assets import AssetStore
from nativ_generation.contracts import GenerationError, ProviderResult

class GenerationAssetTests(unittest.TestCase):
    def setUp(self):
        self.tmp=tempfile.TemporaryDirectory(); self.repo=GenerationRepository(Path(self.tmp.name)); self.store=AssetStore(self.repo)
        self.job=self.repo.submit('music',{'model':'fixture','prompt':'test'},{'id':'fixture','deployment':'local'},'one')
        self.job=self.repo.begin_attempt(self.job['job_id']); self.repo.dispatch(self.job['job_id'],self.job['attempt_id'])
        self.work=self.store.attempt_dir(self.job)
        self.audio=self.work/'candidate.wav'
        with wave.open(str(self.audio),'wb') as w:
            w.setparams((2,2,16000,0,'NONE','not compressed'))
            w.writeframes(b''.join(struct.pack('<hh',int(1000*math.sin(i/20)),int(1000*math.sin(i/20))) for i in range(1600)))
    def tearDown(self): self.repo.close(); self.tmp.cleanup()
    def test_publish_validates_and_session_reference_blocks_trash(self):
        result=self.store.publish(self.job,ProviderResult(self.audio),threading.Event())
        self.assertEqual(result['state'],'succeeded'); a=self.repo.asset(result['asset_id'])
        self.assertEqual(a['metadata']['sample_rate'],16000); self.assertEqual(a['metadata']['channels'],2)
        with self.assertRaises(GenerationError): self.store.trash(a['asset_id'])
        self.repo.delete_reference(a['asset_id'],'session:'+self.job['session_id'],1)
        self.assertTrue(self.store.trash(a['asset_id'])['trashed']); self.assertFalse(self.store.restore(a['asset_id'])['trashed'])
    def test_cancel_after_validation_never_publishes(self):
        self.repo.cancel(self.job['job_id'])
        with self.assertRaises(GenerationError): self.store.publish(self.job,ProviderResult(self.audio),threading.Event())
        self.assertIsNone(self.repo.get_job(self.job['job_id'])['asset_id'])
    def test_escape_candidate_rejected(self):
        with self.assertRaises(GenerationError): self.store.publish(self.job,ProviderResult(Path('/etc/hosts')),threading.Event())
    def test_recovery_completes_validated_publication_without_regeneration(self):
        original=self.store._finish_publication
        self.store._finish_publication=lambda *a: (_ for _ in ()).throw(RuntimeError('crash'))
        with self.assertRaises(RuntimeError): self.store.publish(self.job,ProviderResult(self.audio),threading.Event())
        self.store._finish_publication=original; self.store.recover()
        self.assertEqual(self.repo.get_job(self.job['job_id'])['state'],'succeeded')
    def test_no_empty_or_invalid_media_success(self):
        self.audio.write_bytes(b'not wave')
        with self.assertRaises(GenerationError): self.store.publish(self.job,ProviderResult(self.audio),threading.Event())
        self.assertIsNone(self.repo.get_job(self.job['job_id'])['asset_id'])
    def test_poster_symlink_cannot_expose_a_file_outside_library(self):
        result=self.store.publish(self.job,ProviderResult(self.audio),threading.Event())
        with tempfile.TemporaryDirectory() as outside:
            sentinel=Path(outside)/'private';sentinel.write_text('private')
            (self.repo.root/'derivatives'/(result['asset_id']+'-poster.jpg')).symlink_to(sentinel)
            with self.assertRaises(GenerationError) as error:self.store.poster(result['asset_id'])
            self.assertEqual(error.exception.code,'invalid_storage_path')
