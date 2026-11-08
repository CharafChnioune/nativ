from pathlib import Path
import sys
import tempfile
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parents[2] / 'PythonDistribution/Overlay'))
try:
    from nativ_music import workers
except ImportError:
    workers = None


class MusicWorkerTests(unittest.TestCase):
    def test_minimax_requires_one_finite_stereo_44100_result(self):
        self.assertIsNotNone(workers, 'Music worker implementation is required')
        from types import SimpleNamespace
        from unittest.mock import patch
        import math
        class Audio:
            def __init__(self, rows): self.rows = rows; self.shape = (len(rows), 2)
        numerical = SimpleNamespace(asarray=lambda a: a.rows,
            isfinite=lambda rows: SimpleNamespace(all=lambda: all(math.isfinite(x) for row in rows for x in row)))
        good = SimpleNamespace(audio=Audio([[0, 0]] * 441), sample_rate=44100)
        with patch.dict(sys.modules, numpy=numerical):
            self.assertEqual(workers.validate_minimax_results([good])[1], 44100)
            for results in ([], [good, good], [SimpleNamespace(audio=Audio([[float('nan'), 0]]), sample_rate=44100)],
                            [SimpleNamespace(audio=Audio([[0, 0]] * 441), sample_rate=32000)]):
                with self.assertRaises(ValueError): workers.validate_minimax_results(results)

    def test_ace_fixed_seed_and_manual_lyrics_disable_rewrite(self):
        self.assertIsNotNone(workers, 'Music worker implementation is required')
        params, config = workers.ace_parameters(dict(prompt='warm', lyrics='  Exact words\n', instrumental=False, seed=42, duration_seconds=30))
        self.assertEqual(params['lyrics'], '  Exact words\n')
        self.assertFalse(params['use_cot_caption']); self.assertFalse(params['use_cot_metas'])
        self.assertFalse(config['use_random_seed']); self.assertEqual(config['seeds'], [42])
        self.assertEqual(config['batch_size'], 1); self.assertEqual(config['audio_format'], 'wav')
        self.assertEqual(params['inference_steps'], 8); self.assertEqual(params['shift'], 1)

    def test_stable_cli_keeps_free_models_and_posttrained_cfg_fixed(self):
        self.assertIsNotNone(workers, 'Music worker implementation is required')
        command = workers.stable_arguments(dict(prompt='Piano', duration_seconds=30, seed=7), Path('/private/candidate.wav'))
        self.assertIn('--free-models', command)
        self.assertEqual(command[command.index('--cfg')+1], '1.0')
        self.assertEqual(command[command.index('--dit')+1], 'sm-music')
        self.assertNotIn('--play', command)

    def test_worker_handshakes_before_request_without_model_imports(self):
        self.assertIsNotNone(workers, 'Music worker implementation is required')
        import subprocess, os, json
        runtime = 'minimax-music3-mlx-0.6.4'
        environment = dict(os.environ, PYTHONPATH=str(Path(__file__).resolve().parents[2] / 'PythonDistribution/Overlay'))
        process = subprocess.Popen([sys.executable, '-m', 'nativ_music.workers', '--runtime-id', runtime],
            stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True, env=environment)
        try:
            handshake = json.loads(process.stdout.readline())
            self.assertEqual(handshake['runtime_id'], runtime)
            self.assertEqual(handshake['worker'], 'nativ-music')
            with tempfile.TemporaryDirectory() as directory:
                process.stdin.write(json.dumps(dict(protocol=1, type='generate', provider='minimax_mlx',
                    output_dir=directory, request={}, prepared={})) + '\n'); process.stdin.flush()
                remainder, diagnostic = process.communicate(timeout=5)
            self.assertEqual(json.loads(remainder)['type'], 'error')
            self.assertNotIn('Traceback', remainder + diagnostic)
        finally:
            if process.poll() is None: process.kill(); process.wait()

    def test_model_receipt_checks_revision_and_file_hash(self):
        self.assertIsNotNone(workers, 'Music worker implementation is required')
        import hashlib, json
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory); (root/'weight').write_bytes(b'fixture')
            receipt = dict(profile='fixture', revision='a'*40, files={'weight': hashlib.sha256(b'fixture').hexdigest()})
            (root/'nativ-model.json').write_text(json.dumps(receipt))
            workers.verify_receipt(root, 'fixture', 'a'*40)
            (root/'weight').write_bytes(b'changed')
            with self.assertRaises(ValueError): workers.verify_receipt(root, 'fixture', 'a'*40)


if __name__ == '__main__': unittest.main()
