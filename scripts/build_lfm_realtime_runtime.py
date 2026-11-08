#!/usr/bin/env python3
"""Build the pinned local-only LFM helper; model downloads are explicit.

All generated artifacts stay under build/lfm-realtime by default. Never modifies
an installed app or the user's model cache. No shell interpolation is used.
"""
import argparse
import hashlib
import json
import pathlib
import platform
import shutil
import subprocess
import urllib.request

ROOT = pathlib.Path(__file__).resolve().parents[1]
MANIFEST = ROOT / 'ThirdParty/LFMRealtime/runtime-manifest.json'

def read_manifest():
    return json.loads(MANIFEST.read_text())

def verify_artifact(path, artifact):
    path = pathlib.Path(path)
    digest = hashlib.sha256()
    with path.open('rb') as stream:
        for chunk in iter(lambda: stream.read(8 * 1024 * 1024), b''):
            digest.update(chunk)
    if path.stat().st_size != artifact['size'] or digest.hexdigest() != artifact['sha256']:
        raise ValueError('artifact integrity mismatch: ' + str(path))
    return digest.hexdigest()

def run(args, **kwargs):
    subprocess.run([str(arg) for arg in args], check=True, timeout=1800, **kwargs)

def download(path, url, artifact):
    if path.exists():
        verify_artifact(path, artifact)
        return
    partial = path.with_suffix(path.suffix + '.partial')
    try:
        with urllib.request.urlopen(url, timeout=30) as source, partial.open('wb') as dest:
            shutil.copyfileobj(source, dest, 8 * 1024 * 1024)
        verify_artifact(partial, artifact)
        partial.replace(path)
    finally:
        partial.unlink(missing_ok=True)

def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--build-root', type=pathlib.Path, default=ROOT / 'build/lfm-realtime')
    parser.add_argument('--jobs', type=int, choices=range(1, 5), default=3)
    parser.add_argument('--download-models', action='store_true')
    parser.add_argument('--quantizations', nargs='+', choices=['Q8_0', 'Q4_K_M'], default=['Q8_0', 'Q4_K_M'])
    parser.add_argument('--verify-only', action='store_true')
    parser.add_argument('--skip-build', action='store_true')
    args = parser.parse_args()
    manifest = read_manifest()
    root = args.build_root.resolve()
    root.mkdir(parents=True, exist_ok=True)
    models = root / 'models'
    models.mkdir(exist_ok=True)
    model = manifest['model']
    artifacts = {key: model['artifacts'][key] for key in args.quantizations + ['projector']}
    if args.download_models or args.verify_only:
        for artifact in artifacts.values():
            path = models / artifact['filename']
            if args.download_models and not args.verify_only:
                download(path, 'https://huggingface.co/' + model['repository'] + '/resolve/' + model['revision'] + '/' + artifact['filename'], artifact)
            verify_artifact(path, artifact)
            print('Verified', path, flush=True)
    if args.verify_only or args.skip_build:
        return
    if platform.system() != 'Darwin' or platform.machine() != 'arm64':
        raise SystemExit('The validated helper build requires macOS arm64.')
    source = root / 'llama.cpp'
    if not source.exists():
        run(['git', 'clone', '--filter=blob:none', '--no-checkout', manifest['runtime']['repository'], source])
    patch = ROOT / 'ThirdParty/LFMRealtime' / manifest['runtime']['patches'][0]['filename']
    if hashlib.sha256(patch.read_bytes()).hexdigest() != manifest['runtime']['patches'][0]['sha256']:
        raise SystemExit('Runtime patch integrity mismatch')
    current_diff = subprocess.check_output(['git', '-C', str(source), 'diff', '--binary', '--unified=1'])
    if current_diff and current_diff != patch.read_bytes():
        raise SystemExit('Refusing to overwrite modified runtime sources')
    run(['git', '-C', source, 'checkout', '--detach', manifest['runtime']['commit']])
    sha = subprocess.check_output(['git', '-C', str(source), 'rev-parse', 'HEAD'], text=True).strip()
    if sha != manifest['runtime']['commit']:
        raise SystemExit('Runtime source pin mismatch')
    if not current_diff:
        run(['git', '-C', source, 'apply', '--check', patch])
        run(['git', '-C', source, 'apply', patch])
    build = root / 'cmake'
    run(['cmake', '-S', source, '-B', build] + manifest['runtime']['buildFlags'])
    run(['cmake', '--build', build, '--target', 'llama-server', '--parallel', args.jobs])
    runtime = root / 'runtime'
    (runtime / 'bin').mkdir(parents=True, exist_ok=True)
    helper = runtime / 'bin/llama-server'
    staged_helper = helper.with_name('llama-server.buildtmp')
    shutil.copy2(build / 'bin/llama-server', staged_helper)
    staged_helper.replace(helper)
    shutil.copy2(source / 'LICENSE', runtime / 'LICENSE-llama.cpp')
    shutil.copytree(ROOT / 'ThirdParty/LFMRealtime/licenses', runtime / 'licenses', dirs_exist_ok=True)
    shutil.copy2(patch, runtime / patch.name)
    shutil.copy2(MANIFEST, runtime / 'runtime-manifest.json')
    dependencies = subprocess.check_output(['otool', '-L', str(helper)], text=True)
    if '/opt/homebrew/' in dependencies or '@rpath/' in dependencies:
        raise SystemExit('Unbundled dependency in helper:\n' + dependencies)
    evidence = {'runtimeCommit': sha, 'patches': manifest['runtime']['patches'], 'version': subprocess.check_output([str(helper), '--version'], stderr=subprocess.STDOUT, text=True).strip(), 'helper': str(helper), 'sha256': hashlib.sha256(helper.read_bytes()).hexdigest(), 'dependencies': dependencies}
    (runtime / 'build-evidence.json').write_text(json.dumps(evidence, indent=2) + '\n')
    print(json.dumps(evidence, indent=2))

if __name__ == '__main__':
    main()
