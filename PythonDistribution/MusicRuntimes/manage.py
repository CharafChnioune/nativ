#!/usr/bin/env python3
"""Explicit managed music preparation. Never imported at ordinary app startup.

The host may import these functions for its cancellable setup flow. Release
builders pass a standalone Python 3.12 prefix; no Homebrew/uv is required by an
installed app. Models are never fetched as a side effect of runtime launch.
"""
from __future__ import annotations
import argparse
import hashlib
import importlib.util
import json
import os
from pathlib import Path, PurePosixPath
import shutil
import signal
import subprocess
import sys
import tarfile
import tempfile
from threading import Event
from urllib.parse import urlsplit, quote
from urllib.request import Request, HTTPRedirectHandler, build_opener

ROOT = Path(__file__).resolve().parent


def digest(path):
    value=hashlib.sha256()
    with Path(path).open('rb') as stream:
        for chunk in iter(lambda: stream.read(1024*1024), b''): value.update(chunk)
    return value.hexdigest()


def check(cancel):
    if cancel.is_set(): raise InterruptedError('Music preparation cancelled')


class Redirects(HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        parsed=urlsplit(newurl)
        if parsed.scheme != 'https' or not (parsed.hostname == 'huggingface.co' or parsed.hostname.endswith(('.huggingface.co', '.hf.co'))):
            raise ValueError('Unexpected model download redirect')
        redirected=super().redirect_request(req, fp, code, msg, headers, newurl)
        if parsed.hostname != urlsplit(req.full_url).hostname:
            redirected.remove_header('Authorization')
        return redirected


def download(url, target, size, sha256, cancel, emit, token=None):
    check(cancel); target=Path(target)
    target.parent.mkdir(parents=True,exist_ok=True)
    if target.is_symlink(): raise ValueError('Managed target may not be a symlink')
    if target.is_file() and target.stat().st_size == size and digest(target) == sha256: return
    partial=target.with_name(target.name+'.partial')
    if partial.is_symlink(): raise ValueError('Managed partial may not be a symlink')
    offset=partial.stat().st_size if partial.exists() else 0
    if offset >= size: partial.unlink();offset=0
    if shutil.disk_usage(target.parent).free < size-offset+64*1024*1024: raise OSError('Insufficient disk space for music download')
    headers={'Range':f'bytes={offset}-'} if offset else {}
    if token and urlsplit(url).hostname == 'huggingface.co': headers['Authorization']='Bearer '+token
    response=build_opener(Redirects()).open(Request(url,headers=headers),timeout=30)
    if offset and response.status != 206: offset=0
    if response.status not in (200,206): raise ValueError('Unexpected download response')
    received=offset
    with response, partial.open('ab' if offset else 'wb') as stream:
        while True:
            check(cancel)
            chunk=response.read(1024*1024)
            if not chunk:break
            received+=len(chunk)
            if received>size:raise ValueError('Download exceeded pinned size')
            stream.write(chunk);emit('downloading',received/size)
        stream.flush();os.fsync(stream.fileno())
    if received != size or digest(partial) != sha256:
        partial.unlink(missing_ok=True);raise ValueError('Download integrity check failed')
    partial.replace(target)


def prepare_models(manifest,destination,cancel,emit,*,accepted_licenses=False,token=None):
    check(cancel)
    if not accepted_licenses:raise ValueError('Review and accept the pinned runtime/model license terms before download')
    destination=Path(destination)
    if destination.is_symlink():raise ValueError('Managed model root may not be a symlink')
    destination.mkdir(parents=True,exist_ok=True);destination=destination.resolve()
    files=manifest['models']['files'];required=sum(x['bytes'] for x in files if not (destination/x['path']).is_file())
    if shutil.disk_usage(destination).free < required+64*1024*1024:raise OSError('Insufficient disk space for prepared models')
    inventory={}
    for item in files:
        check(cancel)
        relative=PurePosixPath(item['path'])
        if relative.is_absolute() or '..' in relative.parts:raise ValueError('Invalid model manifest path')
        path=destination.joinpath(*relative.parts)
        if not path.resolve().is_relative_to(destination):raise ValueError('Model target escapes its managed root')
        url='https://huggingface.co/'+item['repo']+'/resolve/'+item['revision']+'/'+quote(item['remote_path'],safe='/')
        download(url,path,item['bytes'],item['sha256'],cancel,emit,token)
        inventory[item['path']]=item['sha256']
    receipt=dict(schema_version=1,profile=manifest['profile_id'],revision=manifest['models']['revision'],files=inventory)
    partial=destination/'nativ-model.json.partial'
    partial.write_text(json.dumps(receipt,sort_keys=True)+'\n');partial.replace(destination/'nativ-model.json')
    emit('prepared',1.0)
    return receipt


def extract_source(archive,destination):
    destination=Path(destination);destination.mkdir(parents=True,exist_ok=True)
    with tarfile.open(archive,'r:gz') as tar:
        members=tar.getmembers()
        for item in members:
            path=PurePosixPath(item.name)
            if path.is_absolute() or '..' in path.parts or not (item.isdir() or item.isfile()):
                raise ValueError('Source archive contains an unsafe member')
            if item.size > 1024*1024*1024:raise ValueError('Source member exceeds limit')
        for item in members:
            parts=PurePosixPath(item.name).parts[1:]
            if not parts:continue
            target=destination.joinpath(*parts)
            if not target.resolve().is_relative_to(destination.resolve()):raise ValueError('Source target escapes root')
            if item.isdir():target.mkdir(parents=True,exist_ok=True)
            else:
                target.parent.mkdir(parents=True,exist_ok=True)
                with tar.extractfile(item) as source,target.open('wb') as output:shutil.copyfileobj(source,output)


def build_runtime(manifest,destination,python_prefix,cancel,emit,*,compute_lease_fd=None):
    """Build an isolated relocatable-prefix candidate for release signing/QA.

    A verified model is prepared separately. Never upgrades Nativ's base prefix.
    Full runtime/native signing qualification remains a release builder gate.
    """
    check(cancel)
    destination=Path(destination)
    if destination.exists():raise ValueError('Build into a new managed runtime directory')
    prefix=Path(python_prefix).resolve()
    interpreter=prefix/'bin/python3'
    if not interpreter.is_file():raise ValueError('Provide the bundled standalone Python prefix')
    version=subprocess.check_output([str(interpreter),'-c','import sys;print(".".join(map(str,sys.version_info[:2])))'],text=True).strip()
    if version!='3.12':raise ValueError('Music runtimes require Python 3.12')
    stage=destination.with_name(destination.name+'.partial')
    if stage.exists():raise ValueError('A previous partial build requires explicit cleanup or repair')
    stage.mkdir(parents=True)
    try:
        shutil.copytree(prefix,stage/'python',symlinks=True)
        candidates=[ROOT.parent/'Overlay',*sorted((prefix/'lib').glob('python*/site-packages'))]
        signing_helper=next((root/'nativ_generation/runtime_signing.py' for root in candidates if (root/'nativ_generation/runtime_signing.py').is_file()),None)
        if signing_helper is None:raise ValueError('The trusted Python prefix is missing its managed interpreter signing helper')
        spec=importlib.util.spec_from_file_location('nativ_owned_runtime_signing',signing_helper)
        signing=importlib.util.module_from_spec(spec);spec.loader.exec_module(signing)
        signing.prepare_interpreter(stage,prefix,cancel)
        if manifest['provider']!='minimax_mlx':
            for site in (stage/'python/lib').glob('python*/site-packages'):
                for child in site.iterdir():
                    if child.name.startswith(('pip','setuptools','_distutils_hack','distutils-precedence')):continue
                    if child.is_dir() and not child.is_symlink():shutil.rmtree(child)
                    else:child.unlink()
            lock=(ROOT/manifest['lock']['path']).resolve()
            if digest(lock)!=manifest['lock']['sha256']:raise ValueError('Runtime dependency lock integrity failed')
            python=stage/'python/bin/python3'
            clean={k:v for k,v in os.environ.items() if k in ('PATH','HOME','TMPDIR','SYSTEMROOT')}
            clean.update(PYTHONHOME=str(stage/'python'),PYTHONNOUSERSITE='1',PIP_DISABLE_PIP_VERSION_CHECK='1')
            commands=[]
            if manifest.get('bootstrap_lock'):
                bootstrap=ROOT/manifest['bootstrap_lock']['path']
                if digest(bootstrap)!=manifest['bootstrap_lock']['sha256']:raise ValueError('Build bootstrap lock integrity failed')
                commands.append([str(python),'-m','pip','install','--require-hashes','--no-deps','--only-binary=:all:','-r',str(bootstrap)])
            commands.append([str(python),'-m','pip','install','--require-hashes','--no-build-isolation','-r',str(lock)])
            for command in commands:
                candidates=[ROOT.parent/'Overlay',*sorted((prefix/'lib').glob('python*/site-packages'))]
                helper=next((root/'nativ_generation/setup_command.py' for root in candidates if (root/'nativ_generation/setup_command.py').is_file()),None)
                if helper is None:raise ValueError('The trusted Python prefix is missing its setup process supervisor')
                spec=importlib.util.spec_from_file_location('nativ_owned_setup_command',helper)
                module=importlib.util.module_from_spec(spec);spec.loader.exec_module(module)
                code=module.run_setup_command(command,env=clean,cancel=cancel,compute_lease_fd=compute_lease_fd)
                if code:raise ValueError('Locked dependency installation failed; inspect builder package availability')
        source=manifest.get('source')
        if source:
            archive=stage/'source.tar.gz'
            download(source['url'],archive,source['bytes'],source['sha256'],cancel,emit)
            extract_source(archive,stage/'source');archive.unlink()
            if manifest['provider']=='acestep':
                site=next((stage/'python/lib').glob('python*/site-packages'))
                shutil.copytree(stage/'source/acestep',site/'acestep',dirs_exist_ok=True)
        shutil.copytree(ROOT/'licenses',stage/'licenses',dirs_exist_ok=True)
        # Music and shared contracts are copied into the child prefix, outside source checkout.
        site=next((stage/'python/lib').glob('python*/site-packages'))
        candidates=[ROOT.parent/'Overlay',*sorted((prefix/'lib').glob('python*/site-packages'))]
        overlay=next((candidate for candidate in candidates if all((candidate/name).is_dir() for name in ('nativ_music','nativ_generation'))),None)
        if overlay is None:raise ValueError('The packaged music worker modules are missing from the trusted standalone prefix')
        for package in ('nativ_music','nativ_generation'):
            shutil.copytree(overlay/package,site/package,dirs_exist_ok=True,ignore=shutil.ignore_patterns('__pycache__','*.pyc'))
        (stage/'nativ-runtime.json').write_text(json.dumps(dict(id=manifest['id'],lock_sha256=manifest['lock']['sha256'],qualification='unqualified',
            builder_sha256=digest(__file__),runtime_signing_sha256=digest(signing_helper),interpreter_sha256=digest(stage/'python/bin/python3')))+'\n')
        stage.replace(destination);emit('runtime_built',1.0)
    except BaseException:
        # Leave only this known private candidate for review/explicit repair; never touch completed runtimes.
        raise
    return destination


def main():
    parser=argparse.ArgumentParser()
    parser.add_argument('action',choices=('models','build'))
    parser.add_argument('--runtime',required=True)
    parser.add_argument('--destination',type=Path,required=True)
    parser.add_argument('--python-prefix',type=Path)
    parser.add_argument('--accept-licenses',action='store_true')
    args=parser.parse_args()
    if not args.runtime.replace('-','').replace('.','').isalnum():raise ValueError('Invalid runtime ID')
    manifest=json.loads((ROOT/(args.runtime+'.json')).read_text())
    cancel=Event();signal.signal(signal.SIGTERM,lambda *_:cancel.set());signal.signal(signal.SIGINT,lambda *_:cancel.set())
    emit=lambda stage,progress:print(json.dumps(dict(stage=stage,progress=progress)),flush=True)
    if args.action=='models':prepare_models(manifest,args.destination,cancel,emit,accepted_licenses=args.accept_licenses,token=os.environ.get('HF_TOKEN'))
    else:
        if not args.accept_licenses:raise ValueError('Review and accept runtime license terms first')
        build_runtime(manifest,args.destination,args.python_prefix,cancel,emit)


if __name__=='__main__':main()
