"""Hold the compute lease until every owned model/encoder process is terminated.

A live group leader survives a model crash. Parent-pipe EOF terminates the whole
owned group, including this guardian; its process identity cannot have been reused.
"""
import argparse
import json
import os
import selectors
import signal
import subprocess
import sys

def main():
    parser=argparse.ArgumentParser();parser.add_argument('--parent-fd',type=int,required=True);parser.add_argument('--module',required=True);parser.add_argument('args',nargs=argparse.REMAINDER)
    args=parser.parse_args()
    if args.module not in {'nativ_music.workers','nativ_video.workers','nativ_generation.remote_worker'}:raise SystemExit(2)
    forwarded=args.args[1:] if args.args[:1]==['--'] else args.args
    worker=subprocess.Popen([sys.executable,'-m',args.module,*forwarded],stdin=sys.stdin,stdout=sys.stdout,stderr=sys.stderr,close_fds=True)
    selector=selectors.DefaultSelector();selector.register(args.parent_fd,selectors.EVENT_READ)
    reported=False
    while True:
        for key,_ in selector.select(.05):
            if not os.read(key.fd,64):os.killpg(os.getpgrp(),signal.SIGKILL)
        code=worker.poll()
        if code is not None and not reported:
            print(json.dumps({'type':'worker_exit','code':code}),flush=True);reported=True

if __name__=='__main__':main()
