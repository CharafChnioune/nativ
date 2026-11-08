"""Service-owned media. Validated publication is journaled before atomic rename."""
from __future__ import annotations
import array
import hashlib
import json
import math
import os
from pathlib import Path
import shutil
import sys
import wave
from .contracts import GenerationError
from .repository import encode, identifier, fingerprint, TERMINAL

LIMITS={'music':1024**3,'video':2*1024**3}

def digest_file(path):
    digest=hashlib.sha256()
    with Path(path).open('rb') as source:
        for block in iter(lambda:source.read(1024*1024),b''): digest.update(block)
    return digest.hexdigest()

def sync_directory(path):
    descriptor=os.open(path,os.O_RDONLY)
    try: os.fsync(descriptor)
    finally: os.close(descriptor)

def probe_audio(path):
    """Decode every frame, with bounded memory; never derive duration from a request."""
    peaks=[]; maximum=0.0; frames=0
    try:
        # SoundFile also handles encoded music and FLOAT WAV in the bundled runtime.
        import soundfile as sf
        with sf.SoundFile(str(path)) as source:
            rate,channels=source.samplerate,source.channels
            if rate<=0 or channels not in (1,2): raise ValueError()
            interval=max(1,math.ceil(len(source)/256))
            while True:
                block=source.read(min(interval,65536),dtype='float32',always_2d=True)
                if not len(block): break
                import numpy as np
                if not np.isfinite(block).all(): raise ValueError()
                peak=float(np.abs(block).max()); maximum=max(maximum,peak); frames+=len(block)
                if len(peaks)<256: peaks.append(peak)
    except ImportError:
        # Stdlib contract tests need no optional inference or decoder dependency.
        try:
            with wave.open(str(path),'rb') as source:
                rate,channels,width=source.getframerate(),source.getnchannels(),source.getsampwidth()
                if width!=2 or channels not in (1,2) or rate<=0: raise ValueError()
                interval=max(1,math.ceil(source.getnframes()/256))
                while True:
                    raw=source.readframes(min(interval,65536))
                    if not raw: break
                    pcm=array.array('h',raw)
                    if sys.byteorder!='little': pcm.byteswap()
                    peak=max(abs(x) for x in pcm)/32768; maximum=max(maximum,peak)
                    frames+=len(pcm)//channels
                    if len(peaks)<256: peaks.append(peak)
        except Exception:
            raise GenerationError('invalid_media','The audio could not be fully decoded. Repair the managed decoder or check the provider output.',status=502) from None
    except Exception:
        raise GenerationError('invalid_media','The audio contains invalid or unsupported samples.',status=502) from None
    if not frames or maximum==0: raise GenerationError('invalid_media','The provider returned empty or silent audio.',status=502)
    return {'sample_rate':rate,'channels':channels,'frame_count':frames,'duration_seconds':frames/rate,'waveform':peaks,'peak':maximum}

class AssetStore:
    def __init__(self,repository,*,codec_paths=None):
        self.repo=repository; self.root=repository.root; self.codec_paths=codec_paths or {}
        for folder in ('assets','attempts','inputs','derivatives'): (self.root/folder).mkdir(exist_ok=True,mode=0o700)
    def attempt_dir(self,job):
        path=self.root/'attempts'/job['job_id']/job['attempt_id']; path.mkdir(parents=True,exist_ok=True,mode=0o700); return path
    def confined(self,relative):
        path=self.root/relative
        resolved=path.resolve()
        if not resolved.is_relative_to(self.root) or path.is_symlink(): raise GenerationError('invalid_storage_path','The media library contains an unsafe path.',status=500)
        return resolved
    def content(self,asset_id):
        asset=self.repo.asset(asset_id)
        if asset['trashed']: raise GenerationError('asset_trashed','Restore this asset before using it.',status=410)
        path=self.confined(asset['relative_path'])
        if not path.is_file(): raise GenerationError('asset_unavailable','The media file is missing. Restore the library from backup.',status=410)
        return path,asset
    def publish(self,job,result,cancellation):
        work=self.attempt_dir(job).resolve(); source=Path(result.path)
        if source.is_symlink() or not source.resolve().is_relative_to(work) or not source.is_file():
            raise GenerationError('invalid_candidate','The worker did not return an owned media candidate.',status=502)
        size=source.stat().st_size
        if not 0<size<=LIMITS[job['modality']]: raise GenerationError('output_too_large','The generated media is empty or exceeds its import limit.',status=502)
        if cancellation.is_set(): raise GenerationError('cancelled','The generation was cancelled.',status=409)
        suffix=source.suffix.lower()
        if suffix not in ('.wav','.mp3','.flac','.m4a','.ogg','.mp4'): raise GenerationError('invalid_media','Unsupported output container.',status=502)
        aid=identifier(); final=self.root/'assets'/(aid+suffix); partial=work/(aid+'.partial')
        count=0; digest=hashlib.sha256()
        with source.open('rb') as src,partial.open('xb') as dst:
            os.chmod(partial,0o600)
            while True:
                if cancellation.is_set(): raise GenerationError('cancelled','The generation was cancelled.',status=409)
                block=src.read(1024*1024)
                if not block: break
                count+=len(block)
                if count>LIMITS[job['modality']]: raise GenerationError('output_too_large','The output grew beyond its import limit.',status=502)
                dst.write(block); digest.update(block)
            dst.flush(); os.fsync(dst.fileno())
        if count!=size: raise GenerationError('candidate_changed','The output changed during validation.',status=502)
        # Bind validation to the private copy, never to a still-mutable provider path.
        if digest_file(source)!=digest.hexdigest(): raise GenerationError('candidate_changed','The output changed during import.',status=502)
        if job['modality']=='music':
            if self.codec_paths:
                from .audio_media import probe_audio as managed_probe_audio
                metadata=managed_probe_audio(partial,self.codec_paths,cancellation=cancellation)
            else:metadata=probe_audio(partial)
        else:
            from nativ_video.media import probe
            metadata=probe(partial,job['request'],self.codec_paths,cancellation=cancellation)
        metadata['provider_reported']=dict(result.metadata)
        metadata['provenance']={'profile_id':job['profile']['id'],'profile_revision':job['profile'].get('profile_revision'),
                                'accepted_request':job['request'],'inputs':job.get('inputs_provenance',{})}
        mime={'.wav':'audio/wav','.mp3':'audio/mpeg','.flac':'audio/flac','.m4a':'audio/mp4','.ogg':'audio/ogg','.mp4':'video/mp4'}[suffix]
        record={'relative_path':str(final.relative_to(self.root)),'partial':str(partial.relative_to(self.root)),
                'filename':job['modality']+'-'+aid+suffix,'mime_type':mime,'byte_size':count,'sha256':digest.hexdigest(),
                'metadata':metadata,'effective_parameters':dict(result.effective_parameters)}
        with self.repo.transaction():
            current=self.repo.get_job(job['job_id'])
            if current['attempt_id']!=job['attempt_id'] or current['cancel_requested'] or current['state'] in TERMINAL:
                raise GenerationError('invalid_attempt','This generation is no longer eligible to publish.',status=409)
            current.update(state='finalizing',stage='validating',progress=None); self.repo._save(current)
            self.repo.connection.execute('INSERT INTO publications VALUES(?,?,?,?)',(job['job_id'],job['attempt_id'],aid,encode(record)))
        os.replace(partial,final); sync_directory(final.parent)
        return self._finish_publication(job['job_id'],job['attempt_id'],aid,record)
    def _finish_publication(self,jid,attempt,aid,record):
        with self.repo.transaction():
            job=self.repo.get_job(jid)
            if job['attempt_id']!=attempt or job['cancel_requested'] or job['state'] in TERMINAL:
                self.repo.connection.execute('DELETE FROM publications WHERE job_id=?',(jid,))
                self.confined(record['relative_path']).unlink(missing_ok=True)
                raise GenerationError('invalid_attempt','Publication was cancelled.',status=409)
            self.repo.connection.execute('INSERT OR IGNORE INTO assets VALUES(?,?,?,?,?,?,?,?,?,0,?,1)',
                (aid,jid,job['modality'],record['relative_path'],record['filename'],record['mime_type'],record['byte_size'],record['sha256'],self.repo._now(),encode(record['metadata'])))
            owner={'kind':'session','session_id':job['session_id'],'modality':job['modality']}
            self.repo.connection.execute('INSERT OR IGNORE INTO asset_references VALUES(?,?,?,?,?,?)',
                (aid,'session:'+job['session_id'],'live',1,encode(owner),self.repo._now()))
            job.update(state='succeeded',stage='completed',progress=1.0,asset_id=aid,effective_parameters=record['effective_parameters'],provider_outcome='succeeded',remote_reservation='released',error=None)
            self.repo._save(job); self.repo.connection.execute('DELETE FROM publications WHERE job_id=?',(jid,))
            return job
    def recover(self):
        with self.repo.lock: rows=self.repo.connection.execute('SELECT * FROM publications').fetchall()
        for row in rows:
            record=json.loads(row['data']); final=self.confined(record['relative_path']); partial=self.confined(record['partial'])
            candidate=final if final.is_file() else partial
            valid=candidate.is_file() and candidate.stat().st_size==record['byte_size'] and digest_file(candidate)==record['sha256']
            job=self.repo.get_job(row['job_id'])
            if valid and not job['cancel_requested'] and job['attempt_id']==row['attempt_id'] and job['state'] not in TERMINAL:
                if candidate!=final: os.replace(candidate,final); sync_directory(final.parent)
                self._finish_publication(row['job_id'],row['attempt_id'],row['asset_id'],record)
            else:
                with self.repo.transaction():
                    self.repo.connection.execute('DELETE FROM publications WHERE job_id=?',(row['job_id'],))
                candidate.unlink(missing_ok=True)
    def trash(self,aid):
        with self.repo.transaction():
            asset=self.repo.asset(aid)
            if self.repo.usages(aid)['items']: raise GenerationError('asset_in_use','Unlink this asset from every session, chat and artifact before moving it to Trash.',status=409)
            # Files remain at an immutable address. The DB transaction is the trash journal.
            self.repo.connection.execute('UPDATE assets SET trashed=1,revision=revision+1 WHERE id=? AND trashed=0',(aid,))
            return self.repo.asset(aid)
    def restore(self,aid):
        with self.repo.transaction():
            self.repo.asset(aid); self.repo.connection.execute('UPDATE assets SET trashed=0,revision=revision+1 WHERE id=? AND trashed=1',(aid,))
            return self.repo.asset(aid)
    def import_input(self,stream,mime=None):
        from nativ_video.inputs import import_original
        iid=identifier(); path=self.root/'inputs'/iid
        metadata=import_original(stream,path,mime=None if mime=='application/octet-stream' else mime)
        try:
            with self.repo.transaction(): self.repo.connection.execute('INSERT INTO inputs VALUES(?,?,?,?,1)',(iid,str(path.relative_to(self.root)),encode(metadata),self.repo._now()))
        except BaseException: path.unlink(missing_ok=True); raise
        return self.input(iid)
    def poster(self,aid):
        source,asset=self.content(aid)
        target=self.confined('derivatives/'+aid+'-poster.jpg')
        if target.is_file():return target
        from nativ_video.media import _run
        ffmpeg=self.codec_paths.get('ffmpeg')
        if not ffmpeg:raise GenerationError('codec_unavailable','Repair the packaged media encoder.',status=503)
        temporary=target.with_name(aid+'-'+identifier()+'.jpg')
        try:
            _run([ffmpeg,'-nostdin','-v','error','-i',str(source),'-frames:v','1','-vf','scale=640:-2','-q:v','3',str(temporary)],limit=1024*1024)
            if not temporary.is_file() or temporary.stat().st_size>4*1024*1024:raise GenerationError('poster_invalid','The generated poster exceeds its limit.',status=502)
            os.replace(temporary,target);return target
        finally:temporary.unlink(missing_ok=True)
    def input(self,iid):
        with self.repo.lock: row=self.repo.connection.execute('SELECT * FROM inputs WHERE id=?',(iid,)).fetchone()
        if row is None: raise GenerationError('input_not_found','The uploaded reference was not found.',status=404)
        return {'input_id':row['id'],'store_id':self.repo.store_id,'created_at':row['created_at'],'revision':row['revision'],**json.loads(row['metadata'])}
    def input_content(self,iid):
        metadata=self.input(iid)
        return self.confined('inputs/'+iid),metadata
    def delete_input(self,iid):
        with self.repo.transaction():
            self.input(iid)
            # Accepted jobs pin immutable inputs, including historical reproducibility.
            if self.repo.connection.execute('SELECT 1 FROM input_usages WHERE input_id=?',(iid,)).fetchone(): raise GenerationError('input_in_use','This reference is pinned by an accepted generation.',status=409)
            self.repo.connection.execute('DELETE FROM inputs WHERE id=?',(iid,))
        self.confined('inputs/'+iid).unlink(missing_ok=True)
        return {'input_id':iid,'deleted':True}
    def transform_input(self,iid,width,height,transform=None):
        from nativ_video.inputs import materialize,validate_transform
        source,original=self.input_content(iid);recipe=validate_transform(transform)
        if type(width) is not int or type(height) is not int or not 1<=width<=4096 or not 1<=height<=4096 or width*height>8_294_400:
            raise GenerationError('invalid_transform','Preview dimensions exceed the supported video-frame limit.',field='width')
        derivative=fingerprint({'original':original['sha256'],'width':width,'height':height,'transform':recipe})
        target=self.confined('derivatives/'+iid+'-'+derivative+'.png');receipt=self.confined('derivatives/'+iid+'-'+derivative+'.json')
        if target.is_file() and receipt.is_file():
            metadata=json.loads(receipt.read_text())
            if target.stat().st_size==metadata['byte_size'] and digest_file(target)==metadata['sha256']:return metadata
        if len(list((self.root/'derivatives').glob(iid+'-*.png')))>=32:raise GenerationError('preview_limit','This input already has 32 prepared previews. Upload a new reference to explore more transforms.',status=429)
        metadata=materialize(source,target,width=width,height=height,transform=recipe)
        metadata.update(input_id=iid,derivative_id=derivative,store_id=self.repo.store_id,original_sha256=original['sha256'])
        temporary=receipt.with_name(receipt.name+'.'+identifier()+'.partial');temporary.write_text(encode(metadata));os.replace(temporary,receipt)
        return metadata
    def derivative_content(self,iid,derivative):
        self.input(iid)
        if not isinstance(derivative,str) or len(derivative)!=64 or any(c not in '0123456789abcdef' for c in derivative):raise GenerationError('preview_not_found','The prepared reference preview was not found.',status=404)
        path=self.confined('derivatives/'+iid+'-'+derivative+'.png')
        if not path.is_file():raise GenerationError('preview_not_found','Prepare the reference preview again.',status=404)
        return path
    def prepare_inputs(self,job):
        from nativ_video.inputs import materialize
        prepared={}
        for item in job['request'].get('inputs',[]):
            source,original=self.input_content(item['input_id'])
            if digest_file(source)!=original['sha256']: raise GenerationError('input_changed','The immutable reference failed its integrity check.',status=409)
            path=self.attempt_dir(job)/(item['input_id']+'-'+item['role']+'-prepared.png')
            metadata=materialize(source,path,width=job['request']['width'],height=job['request']['height'],transform=item.get('transform'))
            prepared[item['input_id']+':'+item['role']]={**metadata,'path':str(path),'role':item['role'],'original_sha256':original['sha256']}
        return prepared
