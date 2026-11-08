"""Bounded immutable still-image import and transform v1.

Coordinates are normalized to EXIF-oriented source pixels, origin top-left.
Order: EXIF orientation, ICC-to-sRGB, explicit crop, aspect fit, alpha flatten.
Only the caller owns publication/DB pinning; no mutable source paths enter jobs.
"""
from __future__ import annotations
import hashlib
import io
import math
import os
from pathlib import Path
import re
import uuid
from nativ_generation.contracts import GenerationError

MAX_BYTES=25*1024*1024
MAX_PIXELS=40_000_000
MIMES={'PNG':'image/png','JPEG':'image/jpeg','WEBP':'image/webp'}


def _error(message,code='invalid_input',field='inputs'):
    raise GenerationError(code,message,field=field)


def validate_transform(value=None):
    if value is None: value={}
    if not isinstance(value,dict) or set(value)-{'version','fit_policy','crop','background'}:
        _error('Unsupported image-transform fields.','invalid_transform')
    if type(value.get('version',1)) is not int or value.get('version',1)!=1:
        _error('Unsupported image-transform version.','invalid_transform')
    policy=value.get('fit_policy','contain')
    if policy not in ('crop','contain'): _error('Choose crop or contain.','invalid_transform')
    bg=value.get('background','#000000')
    if not isinstance(bg,str) or not re.fullmatch(r'#[0-9a-fA-F]{6}',bg):
        _error('Background must be a six-digit RGB color.','invalid_transform')
    crop=value.get('crop')
    if crop is not None:
        if policy!='crop' or not isinstance(crop,dict) or set(crop)!={'x','y','width','height'}:
            _error('A crop rectangle requires crop fit policy.','invalid_transform')
        for key,n in crop.items():
            if isinstance(n,bool) or not isinstance(n,(int,float)) or not math.isfinite(n):
                _error('Crop coordinates must be finite numbers.','invalid_transform')
        x,y,w,h=(crop[k] for k in ('x','y','width','height'))
        if x<0 or y<0 or w<=0 or h<=0 or x+w>1 or y+h>1:
            _error('The crop must be nonempty and inside the oriented image.','invalid_transform')
        crop={k:float(crop[k]) for k in ('x','y','width','height')}
    return dict(version=1,fit_policy=policy,crop=crop,background=bg.upper())


def _pillow():
    try:
        from PIL import Image, ImageOps, ImageCms
        return Image,ImageOps,ImageCms
    except ImportError:
        _error('The managed image decoder is unavailable. Repair the server runtime.','decoder_unavailable')


def _inspect(path,max_pixels):
    Image,_,_=_pillow()
    try:
        with Image.open(path) as im:
            fmt=im.format
            if fmt not in MIMES or getattr(im,'n_frames',1)!=1:
                _error('Upload a still PNG, JPEG or WebP image.')
            w,h=im.size
            if w<=0 or h<=0 or w*h>max_pixels: _error('The reference exceeds the decoded pixel limit.','input_too_large')
            im.verify()
        with Image.open(path) as im:
            orientation=im.getexif().get(274,1)
            im.load()  # Detect truncated compressed pixels, after the header bound.
        return dict(mime=MIMES[fmt],width=w,height=h,orientation=orientation,
                    oriented_width=h if orientation in (5,6,7,8) else w,
                    oriented_height=w if orientation in (5,6,7,8) else h)
    except GenerationError: raise
    except (Exception,Warning) as exc:
        _error('The image is invalid, truncated or exceeds decoder limits.')


def import_original(stream,destination,*,mime=None,max_bytes=MAX_BYTES,max_pixels=MAX_PIXELS):
    """Stream to a private partial, verify actual format and atomically publish bytes."""
    dst=Path(destination)
    if dst.exists() or dst.is_symlink(): _error('An immutable input cannot be replaced.','input_exists')
    dst.parent.mkdir(parents=True,exist_ok=True)
    partial=dst.parent/('.input-'+uuid.uuid4().hex+'.partial')
    digest=hashlib.sha256(); count=0
    try:
        with partial.open('xb') as out:
            os.chmod(partial,0o600)
            while True:
                chunk=stream.read(min(1024*1024,max_bytes-count+1))
                if not chunk: break
                if not isinstance(chunk,bytes): _error('The input stream must contain bytes.')
                count+=len(chunk)
                if count>max_bytes: _error('The reference exceeds the encoded byte limit.','input_too_large')
                digest.update(chunk); out.write(chunk)
            out.flush(); os.fsync(out.fileno())
        if count==0: _error('The uploaded image is empty.')
        metadata=_inspect(partial,max_pixels)
        if mime and mime.split(';',1)[0].strip().lower()!=metadata['mime']:
            _error('The declared image type does not match its bytes.','mime_mismatch')
        # Link is atomic and fails on an existing destination, unlike replace.
        os.link(partial,dst); partial.unlink()
        directory_fd=os.open(dst.parent,os.O_RDONLY)
        try: os.fsync(directory_fd)
        finally: os.close(directory_fd)
        return dict(metadata,sha256=digest.hexdigest(),byte_size=count,transform_version=1)
    finally:
        partial.unlink(missing_ok=True)


def materialize(source,destination,*,width,height,transform=None):
    """Write deterministic RGB PNG with no location/EXIF metadata or stretch."""
    if type(width) is not int or type(height) is not int or width<=0 or height<=0 or width*height>MAX_PIXELS:
        _error('Invalid target image dimensions.','invalid_transform')
    recipe=validate_transform(transform)
    Image,ImageOps,ImageCms=_pillow()
    _inspect(source,MAX_PIXELS)
    dst=Path(destination); dst.parent.mkdir(parents=True,exist_ok=True)
    partial=dst.parent/('.derivative-'+uuid.uuid4().hex+'.partial')
    try:
        with Image.open(source) as original:
            im=ImageOps.exif_transpose(original)
            oriented=list(im.size)
            icc=im.info.get('icc_profile')
            if icc:
                try:
                    profile=ImageCms.ImageCmsProfile(io.BytesIO(icc))
                    alpha=im.getchannel('A') if 'A' in im.getbands() else None
                    im=ImageCms.profileToProfile(im.convert('RGB'),profile,ImageCms.createProfile('sRGB'),outputMode='RGB')
                    if alpha is not None: im.putalpha(alpha)
                except Exception:
                    _error('The reference has an invalid color profile.','invalid_color_profile')
            else: im=im.convert('RGBA' if 'A' in im.getbands() or 'transparency' in im.info else 'RGB')
            crop=recipe['crop']
            if crop:
                # Explicit nearest-pixel rectangle, edges clamped after validation.
                left=round(crop['x']*im.width); top=round(crop['y']*im.height)
                right=round((crop['x']+crop['width'])*im.width)
                bottom=round((crop['y']+crop['height'])*im.height)
                if right<=left or bottom<=top: _error('The crop is smaller than one source pixel.','invalid_transform')
                im=im.crop((left,top,right,bottom))
            bg=tuple(int(recipe['background'][i:i+2],16) for i in (1,3,5))
            if 'A' in im.getbands():
                base=Image.new('RGB',im.size,bg); base.paste(im,mask=im.getchannel('A')); im=base
            else: im=im.convert('RGB')
            if recipe['fit_policy']=='contain':
                im=ImageOps.contain(im,(width,height),method=Image.Resampling.LANCZOS)
                canvas=Image.new('RGB',(width,height),bg)
                canvas.paste(im,((width-im.width)//2,(height-im.height)//2)); im=canvas
            else:
                im=ImageOps.fit(im,(width,height),method=Image.Resampling.LANCZOS,centering=(0.5,0.5))
            clean=Image.new('RGB',im.size); clean.paste(im)
            clean.save(partial,format='PNG',compress_level=9,optimize=False)
        os.chmod(partial,0o600)
        with partial.open('rb') as f: os.fsync(f.fileno())
        os.replace(partial,dst)
        return dict(sha256=hashlib.sha256(dst.read_bytes()).hexdigest(),byte_size=dst.stat().st_size,
                    mime='image/png',width=width,height=height,oriented_source_size=oriented,
                    transform=recipe,color_space='sRGB',encoding='RGB PNG',metadata_stripped=True)
    finally: partial.unlink(missing_ok=True)
