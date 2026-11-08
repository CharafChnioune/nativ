import importlib.util
from pathlib import Path
from types import SimpleNamespace
import tempfile
import unittest
import os
from unittest.mock import patch

MODULE = Path(__file__).resolve().parents[2] / "PythonDistribution/Overlay/nativ_translation_local.py"
spec = importlib.util.spec_from_file_location("nativ_translation_local", MODULE)
local = importlib.util.module_from_spec(spec)
spec.loader.exec_module(local)


class TranslationLocalAssetsTests(unittest.TestCase):
    def test_hub_download_is_offline_only_inside_translation_request(self):
        calls = []
        def download(*args, **kwargs):
            calls.append(kwargs)
            return "cached"
        hub = SimpleNamespace(snapshot_download=download, hf_hub_download=download)
        def run(request):
            return hub.snapshot_download("auxiliary", local_files_only=False)
        audio = SimpleNamespace(_run_tts_request=run)
        local.install_local_assets_policy(hub, audio)
        with tempfile.TemporaryDirectory() as model:
            request = SimpleNamespace(payload=SimpleNamespace(request=SimpleNamespace(model=model, ref_audio=None, nativ_local_only=True)))
            self.assertEqual(audio._run_tts_request(request), "cached")
        self.assertTrue(calls[-1]["local_files_only"])
        hub.snapshot_download("ordinary")
        self.assertNotIn("local_files_only", calls[-1])

    def test_scope_is_reset_after_failure_and_cached_file_failure_propagates(self):
        calls = []
        def download(*args, **kwargs):
            calls.append(kwargs)
            raise FileNotFoundError("not prepared")
        hub = SimpleNamespace(snapshot_download=download, hf_hub_download=download)
        audio = SimpleNamespace(_run_tts_request=lambda request: hub.hf_hub_download("auxiliary", "file"))
        local.install_local_assets_policy(hub, audio)
        with tempfile.TemporaryDirectory() as model:
            request = SimpleNamespace(payload=SimpleNamespace(request=SimpleNamespace(model=model, ref_audio=None, nativ_local_only=True)))
            with self.assertRaises(FileNotFoundError):
                audio._run_tts_request(request)
        self.assertTrue(calls[-1]["local_files_only"])
        with self.assertRaises(FileNotFoundError):
            hub.hf_hub_download("ordinary", "file")
        self.assertNotIn("local_files_only", calls[-1])

    def test_remote_or_missing_model_and_reference_are_rejected_before_inference(self):
        hub = SimpleNamespace(snapshot_download=lambda *a, **k: None, hf_hub_download=lambda *a, **k: None)
        calls = []
        audio = SimpleNamespace(_run_tts_request=lambda request: calls.append(request))
        local.install_local_assets_policy(hub, audio)
        with tempfile.TemporaryDirectory() as model:
            for path, reference in [("remote/model", None), ("/missing/prepared-model", None), (model, "https://example.com/voice.wav")]:
                request = SimpleNamespace(payload=SimpleNamespace(request=SimpleNamespace(model=path, ref_audio=reference, nativ_local_only=True)))
                with self.assertRaises(ValueError):
                    audio._run_tts_request(request)
        self.assertEqual(calls, [])

    def test_context_is_not_inherited_by_an_unrelated_thread(self):
        from concurrent.futures import ThreadPoolExecutor
        hub = SimpleNamespace(snapshot_download=lambda *a, **k: k, hf_hub_download=lambda *a, **k: k)
        observations = []
        def run(request):
            with ThreadPoolExecutor(max_workers=1) as executor:
                observations.append(executor.submit(hub.snapshot_download, "ordinary").result())
            observations.append(hub.snapshot_download("translation"))
        audio = SimpleNamespace(_run_tts_request=run)
        local.install_local_assets_policy(hub, audio)
        with tempfile.TemporaryDirectory() as model:
            audio._run_tts_request(SimpleNamespace(payload=SimpleNamespace(request=SimpleNamespace(model=model, ref_audio=None, nativ_local_only=True))))
        self.assertNotIn("local_files_only", observations[0])
        self.assertTrue(observations[1]["local_files_only"])

    @unittest.skipUnless(os.environ.get("NATIV_CASCADE_RUNTIME_CHECK") == "1", "requires built Nativ MLX runtime; no model weights are loaded")
    def test_real_mlx_tts_request_preserves_opt_in_at_worker_load(self):
        import huggingface_hub
        import mlx_vlm.server.audio as audio
        from fastapi import FastAPI
        from fastapi.testclient import TestClient
        observations = []
        class PreparedAssetsMissing(Exception): pass
        def download(*args, **kwargs):
            observations.append(kwargs)
            raise PreparedAssetsMissing()
        def get_cached_model(*args, **kwargs):
            # This is the exact first call of the installed synchronous TTS worker.
            return huggingface_hub.snapshot_download("prepared/auxiliary", local_files_only=False)
        authorizations = []
        base = SimpleNamespace(app=FastAPI(), _require_management_api_key=lambda request: authorizations.append(request.url.path))
        with patch.object(huggingface_hub, "snapshot_download", download), patch.object(audio, "get_cached_model", get_cached_model):
            local.install(base)
            with tempfile.TemporaryDirectory() as model:
                payload = audio.AudioSpeechRequest(model=model, input="synthetic fixture", nativ_local_only=True)
                self.assertTrue(payload.nativ_local_only)
                request = SimpleNamespace(payload=audio.SpeechTaskPayload(request=payload))
                with self.assertRaises(PreparedAssetsMissing):
                    audio._run_tts_request(request)
            self.assertTrue(observations[-1]["local_files_only"])
            with TestClient(base.app) as client:
                response = client.get("/nativ/translation-capabilities")
                self.assertEqual(response.status_code, 200)
                self.assertEqual(response.json(), {"local_speech_assets_policy": 1})
            self.assertEqual(authorizations, ["/nativ/translation-capabilities"])


if __name__ == "__main__":
    unittest.main()
