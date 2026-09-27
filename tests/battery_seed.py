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


if __name__ == "__main__":
    unittest.main()
