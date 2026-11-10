import sys,unittest
from pathlib import Path
sys.path.insert(0,str(Path(__file__).resolve().parents[2]/'PythonDistribution/Overlay'))
from nativ_generation.memory import MemoryGuard
from nativ_generation.contracts import GenerationError

class GenerationMemoryTests(unittest.TestCase):
    def test_16_and_128_gib_are_not_guessed_model_capability_limits(self):
        for gb in (16,128):
            guard=MemoryGuard(read=lambda:{'physical_memory_bytes':gb*1024**3,'system_free_percent':40,'system_swap_bytes':5*1024**3})
            self.assertEqual(guard.current['physical_memory_bytes'],gb*1024**3)
    def test_existing_swap_is_not_misattributed_to_new_model(self):
        now=[0];value={'physical_memory_bytes':16*1024**3,'system_free_percent':30,'system_swap_bytes':5*1024**3}
        guard=MemoryGuard(read=lambda:dict(value),clock=lambda:now[0]);now[0]=3;guard.check()
        value['system_swap_bytes']+=513*1024**2;now[0]=6
        with self.assertRaises(GenerationError) as result:guard.check()
        self.assertEqual(result.exception.code,'system_swap_growth')
    def test_critical_pressure_fails_before_worker_dispatch(self):
        with self.assertRaises(GenerationError):MemoryGuard(read=lambda:{'physical_memory_bytes':128*1024**3,'system_free_percent':3,'system_swap_bytes':0})
    def test_unavailable_sensor_does_not_invent_measurement(self):
        guard=MemoryGuard(read=lambda:None);self.assertIsNone(guard.current)
    def test_snapshot_reads_swap_when_the_user_locale_uses_decimal_commas(self):
        from unittest.mock import patch
        from nativ_generation import memory
        def sysctl(args,env=None,**kw):  # real macOS output under LANG=nl_NL.UTF-8 unless LC_ALL=C
            if args[0].endswith('memory_pressure'):return 'System-wide memory free percentage: 63%'
            used='619.69M' if (env or {}).get('LC_ALL')=='C' else '619,69M'
            return f'vm.swapusage: total = 2048.00M  used = {used}  free = 1428.31M  (encrypted)\nhw.memsize: 137438953472'
        with patch.object(memory.sys,'platform','darwin'),patch.object(memory.subprocess,'check_output',side_effect=sysctl):
            self.assertEqual(memory.snapshot()['system_swap_bytes'],int(619.69*1024**2))
