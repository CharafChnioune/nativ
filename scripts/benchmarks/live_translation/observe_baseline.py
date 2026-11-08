#!/usr/bin/env python3
"""One-minute read-only preflight; never starts a helper or changes OS memory state."""
import argparse, datetime, importlib.util, json, pathlib, subprocess, time
ROOT = pathlib.Path(__file__).resolve().parents[3]
spec = importlib.util.spec_from_file_location('endurance', ROOT / 'scripts/benchmarks/live_translation/endurance.py')
module = importlib.util.module_from_spec(spec); spec.loader.exec_module(module)
parser = argparse.ArgumentParser()
parser.add_argument('--output', type=pathlib.Path, required=True)
parser.add_argument('--seconds', type=float, default=60)
parser.add_argument('--reference-swap-mib', type=float, default=18990.62)
args = parser.parse_args()
if args.seconds < 60: parser.error('At least 60 seconds required')
if args.output.exists(): parser.error('Evidence file must be new')
args.output.parent.mkdir(parents=True, exist_ok=True)
start = time.monotonic(); samples = []
result = {'started_utc':datetime.datetime.now(datetime.timezone.utc).isoformat(),
          'scope':'Read-only baseline, no models, microphone, playback or cache changes',
          'first_run_reference_swap_mib':args.reference_swap_mib,
          'criteria':{'seconds':args.seconds,'all_pressure_levels':1,'maximum_swap_range_mib':128,
                      'maximum_absolute_net_swap_change_mib':64,'maximum_swap_mib':args.reference_swap_mib},
          'samples':samples,'status':'collecting'}
while True:
    sample = module.system_sample()
    names = subprocess.check_output(['ps','-axo','comm='], text=True, timeout=3).splitlines()
    sample['elapsed_seconds'] = time.monotonic()-start
    sample['compiler_process_counts'] = {name:sum(pathlib.Path(value.strip()).name == name for value in names)
                                         for name in ('xcodebuild','swift-frontend','swiftc','clang')}
    samples.append(sample)
    module.write_json(args.output,result)
    if len(samples) % 10 == 0: print(json.dumps(sample),flush=True)
    if sample['elapsed_seconds'] >= args.seconds: break
    time.sleep(min(1,max(0,args.seconds-(time.monotonic()-start))))
values = [s['swap_used_mib'] for s in samples]
reasons = []
if any(s['pressure_level'] != 1 for s in samples): reasons.append('OS pressure was not normal throughout')
if max(values)-min(values)>128: reasons.append('Swap range exceeded 128 MiB')
if abs(values[-1]-values[0])>64: reasons.append('Absolute net swap change exceeded 64 MiB')
if max(values)>args.reference_swap_mib: reasons.append('Swap exceeds original first-run baseline; no raised baseline allowed')
result.update(status='not-ready' if reasons else 'ready', reasons=reasons,
              ended_utc=datetime.datetime.now(datetime.timezone.utc).isoformat(),
              duration_seconds=samples[-1]['elapsed_seconds'], swap_range_mib=max(values)-min(values),
              net_swap_change_mib=values[-1]-values[0], max_swap_mib=max(values))
module.write_json(args.output,result)
print(json.dumps({k:v for k,v in result.items() if k != 'samples'}),flush=True)
raise SystemExit(1 if reasons else 0)
