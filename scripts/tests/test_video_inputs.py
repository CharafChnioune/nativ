import io
import sys
import tempfile
import unittest
from pathlib import Path
sys.path.insert(0,str(Path(__file__).resolve().parents[2]/'PythonDistribution'/'Overlay'))
from nativ_generation.contracts import GenerationError
from nativ_video.inputs import import_original, materialize, validate_transform
try:
    from PIL import Image
except ImportError:
    Image=None

@unittest.skipUnless(Image,'Pillow is required for immutable-image tests')
class VideoInputTests(unittest.TestCase):
    def image(self,size=(12,8),mode='RGB',color='red',fmt='PNG',**kw):
        b=io.BytesIO(); Image.new(mode,size,color).save(b,format=fmt,**kw); return b.getvalue()
    def test_bytes_are_immutable_and_actual_type_checked(self):
        with tempfile.TemporaryDirectory() as td:
            p=Path(td)/'original'; data=self.image()
            m=import_original(io.BytesIO(data),p,mime='image/png')
            self.assertEqual(p.read_bytes(),data); self.assertEqual(m['width'],12)
            with self.assertRaises(GenerationError): import_original(io.BytesIO(data),Path(td)/'wrong',mime='image/jpeg')
            with self.assertRaises(GenerationError): import_original(io.BytesIO(data[:-12]),Path(td)/'truncated')
    def test_orientation_before_crop_and_contain_never_stretches(self):
        with tempfile.TemporaryDirectory() as td:
            src=Path(td)/'src'; dst=Path(td)/'out.png'
            exif=Image.Exif(); exif[274]=6
            src.write_bytes(self.image((12,8),fmt='JPEG',exif=exif))
            meta=materialize(src,dst,width=8,height=8,transform={'version':1,'fit_policy':'contain','background':'#000000','crop':None})
            self.assertEqual(meta['oriented_source_size'],[8,12])
            im=Image.open(dst); self.assertEqual(im.size,(8,8)); self.assertEqual(im.getpixel((0,0)),(0,0,0))
            self.assertEqual(meta['transform']['version'],1); self.assertEqual(len(meta['sha256']),64)
    def test_crop_bounds_animation_and_pixel_limit(self):
        for crop in ({'x':0,'y':0,'width':0,'height':1},{'x':0.8,'y':0,'width':0.5,'height':1},{'x':True,'y':0,'width':1,'height':1}):
            with self.assertRaises(GenerationError): validate_transform({'version':1,'fit_policy':'crop','crop':crop})
        with tempfile.TemporaryDirectory() as td:
            with self.assertRaises(GenerationError): import_original(io.BytesIO(self.image()),Path(td)/'large',max_pixels=10)
            with self.assertRaises(GenerationError): import_original(io.BytesIO(self.image()),Path(td)/'large',max_bytes=4)
    def test_metadata_removed_and_alpha_background_pinned(self):
        with tempfile.TemporaryDirectory() as td:
            src=Path(td)/'src'; dst=Path(td)/'out.png'; src.write_bytes(self.image(mode='RGBA',color=(0,0,0,0)))
            materialize(src,dst,width=12,height=8,transform={'version':1,'fit_policy':'contain','background':'#112233'})
            out=Image.open(dst); self.assertEqual(out.getpixel((5,4)),(17,34,51)); self.assertFalse(out.getexif())
