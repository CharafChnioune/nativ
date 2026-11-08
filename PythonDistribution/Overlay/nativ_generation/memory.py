"""Observed system pressure guard, not a fabricated model RAM requirement."""
from __future__ import annotations
import re
import subprocess
import sys
import time
from .contracts import GenerationError

def snapshot():
    if sys.platform!='darwin':return None
    try:
        pressure=subprocess.check_output(['/usr/bin/memory_pressure','-Q'],text=True,timeout=2,stderr=subprocess.DEVNULL)
        swap=subprocess.check_output(['/usr/sbin/sysctl','vm.swapusage','hw.memsize'],text=True,timeout=2,stderr=subprocess.DEVNULL)
        free=re.search(r'System-wide memory free percentage:\s*(\d+)%',pressure)
        used=re.search(r'used\s*=\s*([\d.]+)([MG])',swap)
        total=re.search(r'hw.memsize:\s*(\d+)',swap)
        if not free or not used or not total:return None
        return {'physical_memory_bytes':int(total[1]),'system_free_percent':int(free[1]),'system_swap_bytes':int(float(used[1])*(1024**2 if used[2]=='M' else 1024**3))}
    except (OSError,ValueError,subprocess.SubprocessError):return None

class MemoryGuard:
    def __init__(self,read=snapshot,clock=time.monotonic):
        self.read=read;self.clock=clock;self.initial=read();self.last=self.clock();self.current=self.initial
        self._validate(self.initial)
    def _validate(self,value):
        if value and value['system_free_percent']<5:
            raise GenerationError('system_memory_pressure','macOS reports critical system memory pressure. Stop other heavy work or use a larger Mac before retrying this unqualified profile.',retryable=True,status=409)
        if value and self.initial and value['system_swap_bytes']-self.initial['system_swap_bytes']>512*1024**2:
            raise GenerationError('system_swap_growth','System swap grew by more than 512 MiB during this attempt. The owned worker was stopped; this is a system observation, not a measured per-model memory requirement.',retryable=True,status=409)
    def check(self):
        now=self.clock()
        if now-self.last<2:return
        self.last=now;self.current=self.read();self._validate(self.current)
