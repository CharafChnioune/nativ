"""Cross-process compute admission shared with the native Translate host."""
from __future__ import annotations
import fcntl
import json
import os
from pathlib import Path
import threading

class ComputeLease:
    def __init__(self,file): self.file=file
    def close(self):
        if self.file is not None:
            fcntl.flock(self.file,fcntl.LOCK_UN);self.file.close();self.file=None
    def __enter__(self):return self
    def __exit__(self,*args):self.close()

class ComputeAdmission:
    def __init__(self,path):
        self.path=Path(path);self.path.parent.mkdir(parents=True,exist_ok=True,mode=0o700)
    def try_acquire(self,owner):
        file=open(self.path,'a+b')
        try:fcntl.flock(file,fcntl.LOCK_EX|fcntl.LOCK_NB)
        except BlockingIOError:file.close();return None
        file.seek(0);file.truncate();file.write(json.dumps({'owner':owner,'pid':os.getpid()}).encode());file.flush()
        return ComputeLease(file)
