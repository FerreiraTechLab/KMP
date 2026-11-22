import sys
import subprocess
import importlib.util
from pathlib import Path
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[1]
SPEC = importlib.util.spec_from_file_location("battery_seed", ROOT / "KMP" / "battery_seed.py")
MODULE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(MODULE)


class BatterySeedTest(unittest.TestCase):
    def test_reads_only_battery_supplies_and_uses_lowest_level(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            for name, kind, capacity in (("BAT0", "Battery", "45"),
                                         ("BAT1", "Battery", "31"),
                                         ("AC", "Mains", "1")):
                supply = root / name
                supply.mkdir()
                (supply / "type").write_text(kind)
                (supply / "capacity").write_text(capacity)
            self.assertEqual(MODULE.battery_percent(root), 31)

    def test_missing_battery_returns_none(self):
        with tempfile.TemporaryDirectory() as directory:
            self.assertIsNone(MODULE.battery_percent(Path(directory)))

    def test_paused_state_round_trip(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "paused.json"
            MODULE.save_paused(path, {"abc", "def"})
            self.assertEqual(MODULE.load_paused(path), {"abc", "def"})


    def test_set_process_name_escapes_killall_python3(self):
        # O PortMaster roda `killall python3` ao sair de um port; o killall compara o comm.
        if not Path("/proc/self/comm").exists():
            self.skipTest("sem /proc")
        code = ("import importlib.util, sys; "
                "spec = importlib.util.spec_from_file_location('m', sys.argv[1]); "
                "m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m); "
                "ok = m.set_process_name('kmp-battery'); "
                "print(ok, open('/proc/self/comm').read().strip())")
        result = subprocess.run([sys.executable, "-c", code, str(ROOT / "KMP" / "battery_seed.py")],
                                capture_output=True, text=True, check=True)
        self.assertEqual(result.stdout.split(), ["True", "kmp-battery"])


if __name__ == "__main__":
    unittest.main()
