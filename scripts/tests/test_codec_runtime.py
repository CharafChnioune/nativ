from pathlib import Path
import hashlib
import importlib.util
import io
import json
import tarfile
import tempfile
import unittest

SCRIPT=Path(__file__).resolve().parents[2]/'PythonDistribution/CodecRuntime/manage.py'


class CodecRuntimeTests(unittest.TestCase):
    def module(self):
        self.assertTrue(SCRIPT.is_file(),'Managed codec builder is required')
        spec=importlib.util.spec_from_file_location('codec_manage',SCRIPT);module=importlib.util.module_from_spec(spec);spec.loader.exec_module(module);return module
    def test_codec_paths_require_receipt_and_hash_never_path_lookup(self):
        module=self.module()
        with tempfile.TemporaryDirectory() as directory:
            root=Path(directory);managed=root/'CodecRuntime/managed';(managed/'bin').mkdir(parents=True)
            for name in ('ffmpeg','ffprobe'):(managed/'bin'/name).write_bytes(b'fixture-'+name.encode())
            with self.assertRaises(ValueError):module.codec_paths(root)
            receipt=dict(id='ffmpeg-9.0.2-x264-b3560',files={f'bin/{name}':hashlib.sha256((managed/'bin'/name).read_bytes()).hexdigest() for name in ('ffmpeg','ffprobe')})
            (managed/'receipt.json').write_text(json.dumps(receipt))
            self.assertEqual(set(module.codec_paths(root)),{'ffmpeg','ffprobe'})
            (managed/'bin/ffmpeg').write_bytes(b'changed')
            with self.assertRaises(ValueError):module.codec_paths(root)
    def test_signing_refresh_preserves_build_hash_and_accepts_signed_bytes(self):
        module=self.module()
        self.assertTrue(hasattr(module,'refresh_signed_receipt'),'Signing changes executable bytes and requires a new verified receipt')
        with tempfile.TemporaryDirectory() as directory:
            root=Path(directory);managed=root/'CodecRuntime/managed';(managed/'bin').mkdir(parents=True)
            hashes={}
            for name in ('ffmpeg','ffprobe'):
                path=managed/'bin'/name;path.write_bytes(b'original');hashes['bin/'+name]=hashlib.sha256(b'original').hexdigest()
            (managed/'receipt.json').write_text(json.dumps(dict(id='ffmpeg-9.0.2-x264-b3560',files=hashes)))
            (managed/'bin/ffmpeg').write_bytes(b'signed-original')
            module.refresh_signed_receipt(root)
            receipt=json.loads((managed/'receipt.json').read_text())
            self.assertEqual(receipt['build_files'],hashes)
            self.assertEqual(set(module.codec_paths(root)),{'ffmpeg','ffprobe'})

    def test_built_codec_real_media_smoke(self):
        module=self.module()
        self.assertTrue(hasattr(module,'smoke'),'Managed codec build must verify real encode/decode')
        output=SCRIPT.parents[2]/'dist/codec-runtime'
        if not (output/'bin/ffmpeg').is_file():self.skipTest('Source codec build is a separate CI prerequisite')
        result=module.smoke(output)
        self.assertEqual(result['frame_count'],24)
        self.assertEqual(result['audio_sample_rate'],44100)
        self.assertTrue(result['audio_finite'])

    def test_codec_source_extract_rejects_traversal(self):
        module=self.module()
        with tempfile.TemporaryDirectory() as directory:
            root=Path(directory);archive=root/'source.tar.gz'
            with tarfile.open(archive,'w:gz') as tar:
                member=tarfile.TarInfo('../escape');member.size=1;tar.addfile(member,io.BytesIO(b'x'))
            with self.assertRaises(ValueError):module.extract(archive,root/'out')

if __name__=='__main__':unittest.main()
