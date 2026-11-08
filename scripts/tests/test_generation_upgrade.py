"""Simulated storage upgrade/reopen regression, not a signed Sparkle update test.

Legacy sentinels match persisted ChatSession/ImageGenerationSession JSON fields and
LiveTranslationSettings' preferences Data. This Python test checks byte preservation;
native Codable compatibility is covered by NativTests, not asserted by this fixture.
No model weights, network, provider execution, installed app or Keychain is used.
"""
import hashlib
import json
from pathlib import Path
import plistlib
import struct
import sys
import tempfile
import threading
import unittest
import wave

sys.path.insert(0, str(Path(__file__).resolve().parents[2] / 'PythonDistribution/Overlay'))
from nativ_generation.assets import AssetStore
from nativ_generation.contracts import GenerationError, ProviderResult
from nativ_generation.repository import GenerationRepository
from nativ_generation.service import GenerationService


def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


class GenerationUpgradePreservationTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.library = Path(self.tmp.name) / 'Library'
        self.support = self.library / 'Application Support/io.github.charafchnioune.nativ'
        self.root = self.support / 'Generations'
        chat_id = '11111111-1111-4111-8111-111111111111'
        image_id = '22222222-2222-4222-8222-222222222222'
        self.legacy = {
            self.support / f'Chat/Sessions/{chat_id}.json': json.dumps(dict(
                id=chat_id, title='Existing chat', createdAt=700000000, updatedAt=700000001,
                messages=[], pinned=True)).encode(),
            self.support / f'ImageGeneration/Sessions/{image_id}.json': json.dumps(dict(
                id=image_id, title='Existing image session', createdAt=700000000, updatedAt=700000001,
                modelKind='imageGeneration', modelID='existing/image',
                draftSettings=dict(count=1, width=512, height=512, seedText='42'), turns=[])).encode(),
            self.library / 'Preferences/io.github.charafchnioune.nativ.plist': plistlib.dumps({
                'io.github.charafchnioune.nativ.translation.preferences.v1': json.dumps(dict(
                    sourceLanguage='nl', targetLanguage='en', quantization='Q8_0',
                    provider='lfm3OmniDirect', overlay=False, experimentalAccepted=True)).encode(),
            }),
            self.support / 'Media/legacy-original.png': (Path(__file__).resolve().parents[2] /
                'Tests/Fixtures/GenerationInputTransform/original.png').read_bytes(),
        }
        for path, data in self.legacy.items():
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_bytes(data)
        self.profile = dict(id='upgrade-fixture', profile_revision='revision-one', deployment='local',
                            modality='music', provider='fixture', defaults={}, qualification='experimental', runtime=None)

    def assert_legacy_unchanged(self):
        for path, data in self.legacy.items():
            self.assertTrue(path.is_file(), path)
            self.assertEqual(path.read_bytes(), data, path)

    def test_introducing_generation_schema_preserves_prefeature_stores(self):
        self.assertFalse(self.root.exists())
        service = GenerationService(self.root, profiles=[self.profile], autostart=False)
        try:
            self.assertEqual(service.repo.connection.execute('PRAGMA user_version').fetchone()[0], 1)
            self.assertEqual(service.repo.list_jobs('music')['items'], [])
            self.assert_legacy_unchanged()
        finally:
            service.close()
        self.assert_legacy_unchanged()

    def test_next_revision_reopens_schema1_jobs_originals_and_reference_tombstones(self):
        repo = GenerationRepository(self.root)
        store = AssetStore(repo)
        try:
            queued = repo.submit('music', {'model': self.profile['id'], 'prompt': 'Held original intent'}, self.profile, 'held')
            job = repo.submit('music', {'model': self.profile['id'], 'prompt': 'Existing original'}, self.profile, 'published')
            job = repo.begin_attempt(job['job_id']); repo.dispatch(job['job_id'], job['attempt_id'])
            output = store.attempt_dir(job) / 'candidate.wav'
            with wave.open(str(output), 'wb') as audio:
                audio.setparams((1, 2, 8000, 0, 'NONE', 'not compressed'))
                audio.writeframes(struct.pack('<800h', *[i % 200 for i in range(800)]))
            source_hash = sha(output)
            published = store.publish(job, ProviderResult(output), threading.Event())
            asset_id = published['asset_id']; original, asset = store.content(asset_id)
            identity = repo.store_id; relative = asset['relative_path']
            self.assertEqual(asset['sha256'], source_hash)
            owner = {'kind': 'chat', 'session_id': 'legacy-chat'}
            ref = repo.put_reference(asset_id, 'chat:stable', 'reserve', 0, owner)
            ref = repo.put_reference(asset_id, 'chat:stable', 'finalize', ref['revision'], owner)
            repo.delete_reference(asset_id, 'session:' + job['session_id'], 1)
            with self.assertRaisesRegex(GenerationError, 'Unlink'):
                store.trash(asset_id)
            self.assertTrue(original.is_file())
        finally:
            repo.close()

        # An app revision is simulated by a changed catalog profile and a fresh
        # service process against the same on-disk schema, not by replacing an app.
        next_profile = dict(self.profile, profile_revision='revision-two')
        def no_provider(*args):
            self.fail('Reopening or rejecting a changed profile must not construct a provider')
        service = GenerationService(self.root, profiles=[next_profile], provider_factory=no_provider, autostart=False)
        try:
            self.assertEqual(service.repo.store_id, identity)
            self.assertEqual(service.repo.connection.execute('PRAGMA user_version').fetchone()[0], 1)
            self.assertEqual(service.repo.get_job(job['job_id'])['state'], 'succeeded')
            self.assertEqual(service.repo.get_job(queued['job_id'])['state'], 'recovery_hold')
            self.assertEqual(service.repo.get_job(queued['job_id'])['request']['prompt'], 'Held original intent')
            usages = service.repo.usages(asset_id)['items']
            self.assertEqual([(item['id'], item['state'], item['revision']) for item in usages],
                             [('chat:stable', 'live', ref['revision'])])
            self.assertEqual(usages[0]['owner'], owner)
            service.repo.delete_reference(asset_id, 'chat:stable', ref['revision'])
            self.assertTrue(service.assets.trash(asset_id)['trashed'])
            # A further fresh-process reopen must retain Trash and restore the
            # exact same original, including released reference tombstones.
            service.close()
            service = GenerationService(self.root, profiles=[next_profile], provider_factory=no_provider, autostart=False)
            self.assertEqual(service.repo.store_id, identity)
            self.assertTrue(service.repo.asset(asset_id)['trashed'])
            service.assets.restore(asset_id)
            restored, restored_asset = service.assets.content(asset_id)
            self.assertEqual(restored_asset['relative_path'], relative)
            self.assertEqual(restored_asset['sha256'], source_hash)
            self.assertEqual(sha(restored), source_hash)
            tombstone = service.repo.connection.execute(
                'SELECT state,revision FROM asset_references WHERE asset_id=? AND id=?',
                (asset_id, 'chat:stable')).fetchone()
            self.assertEqual(tuple(tombstone), ('released', ref['revision'] + 1))
            with self.assertRaises(GenerationError) as late:
                service.repo.put_reference(asset_id, 'chat:stable', 'finalize', ref['revision'], owner)
            self.assertEqual(late.exception.code, 'reference_released')
            service.resume(queued['job_id'])
            resumed = service.repo.begin_attempt(queued['job_id'])
            with self.assertRaises(GenerationError) as changed:
                service._dispatch(resumed)
            self.assertEqual(changed.exception.code, 'profile_changed')
            self.assertFalse(service.repo.get_job(queued['job_id'])['dispatch_intent'])
            self.assert_legacy_unchanged()
            self.assertEqual(len(service.repo.list_jobs('music')['items']), 2)
        finally:
            service.close()
        self.assertEqual(sha(self.root / relative), source_hash)
        self.assert_legacy_unchanged()


if __name__ == '__main__':
    unittest.main()
