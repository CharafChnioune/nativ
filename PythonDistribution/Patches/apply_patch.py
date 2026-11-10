"""Hash-guarded packaging-only remedy for mlx-vlm 0.7.12 image handlers."""
from __future__ import annotations
import ast
import hashlib
import json
from pathlib import Path
import shutil

ROOT=Path(__file__).resolve().parent
MANIFEST=ROOT/'manifest.json'
HELPER=ROOT/'image_execution.py'
TARGETS={
    'images_generations_endpoint':('image_request','width','height','base_seed','created','request_start'),
    'images_edits_endpoint':('image_request','width','height','image_paths','base_seed','created','request_start'),
}


def digest(data):return hashlib.sha256(data).hexdigest()


def transform(source):
    tree=ast.parse(source);lines=source.splitlines(keepends=True);replacements=[]
    found=set()
    for function in tree.body:
        if not isinstance(function,ast.AsyncFunctionDef) or function.name not in TARGETS:continue
        found.add(function.name)
        tries=[node for node in function.body if isinstance(node,ast.Try)]
        if len(tries)!=1 or function.args.args[0].arg!='request':raise ValueError('Unexpected image handler layout')
        operation=tries[0]
        if operation.end_lineno!=function.end_lineno:raise ValueError('Unexpected code after image operation')
        helper='_nativ_execute_'+function.name
        arguments=', '.join(TARGETS[function.name])
        blocking='def '+helper+'('+arguments+'):\n'+''.join(lines[operation.lineno-1:function.end_lineno])+'\n\n'
        # Only parsed DTOs/scalars cross threads. No ASGI Request object does.
        asynchronous=''.join(lines[function.lineno-1:operation.lineno-1])+'    return await run_image('+helper+', '+arguments+')\n'
        replacements.append((function.lineno-1,function.end_lineno,blocking+asynchronous))
    if found!=set(TARGETS):raise ValueError('Expected both image generation and edit handlers')
    for start,end,replacement in sorted(replacements,reverse=True):lines[start:end]=[replacement]
    result='from nativ_image_execution import run_image\n'+''.join(lines)
    ast.parse(result);return result


def apply(site):
    manifest=json.loads(MANIFEST.read_text());site=Path(site);target=site/manifest['path']
    current=target.read_bytes();checksum=digest(current)
    if checksum==manifest['patched_sha256']:
        shutil.copy2(HELPER,site/'nativ_image_execution.py');return
    if checksum!=manifest['source_sha256']:
        raise ValueError('Unsupported mlx-vlm image source. Re-audit and pin its handlers before packaging.')
    patched=transform(current.decode()).encode()
    if digest(patched)!=manifest['patched_sha256']:raise ValueError('Image packaging patch output differs from its reviewed digest')
    temporary=target.with_suffix('.py.nativ-partial');temporary.write_bytes(patched);temporary.replace(target)
    shutil.copy2(HELPER,site/'nativ_image_execution.py')


def verify(site):
    manifest=json.loads(MANIFEST.read_text());site=Path(site)
    if digest((site/manifest['path']).read_bytes())!=manifest['patched_sha256']:raise ValueError('The image control-loop remedy is missing or changed')
    if digest((site/'nativ_image_execution.py').read_bytes())!=digest(HELPER.read_bytes()):raise ValueError('The owned image execution helper differs from its source')
