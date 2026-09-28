import importlib.util
from pathlib import Path
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[1]
SPEC = importlib.util.spec_from_file_location("network_metrics", ROOT / "KMP/network_metrics.py")
METRICS = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(METRICS)


class NetworkMetricsTest(unittest.TestCase):
    def test_peer_scope(self):
        self.assertEqual(METRICS.peer_scope("192.168.1.20"), "local")
        self.assertEqual(METRICS.peer_scope("100.64.0.1"), "remote")
        self.assertEqual(METRICS.peer_scope("8.8.8.8"), "remote")

    def test_battery_uses_lowest_valid_value(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            for name, value in (("BAT0", "75"), ("BAT1", "42"), ("AC", "100")):
                supply = root / name
                supply.mkdir()
                (supply / "type").write_text("Mains" if name == "AC" else "Battery")
                (supply / "capacity").write_text(value)
            self.assertEqual(METRICS.battery_percent(root), 42)

    def test_torrent_metrics_separates_peers_and_web_seeds(self):
        item = {"gid": "abc", "status": "active", "downloadSpeed": "2048",
                "uploadSpeed": "128", "connections": "2", "files": [{"uris": [
                    {"uri": "https://example.test/game.zip", "status": "used"}]}]}
        result = METRICS.torrent_metrics(
            lambda method, params: [{"ip": "192.168.1.2"}, {"ip": "8.8.8.8"}], item)
        self.assertEqual(result["localPeers"], 1)
        self.assertEqual(result["remotePeers"], 1)
        self.assertEqual(result["webSeedsActive"], 1)
        self.assertEqual(result["downloadBps"], 2048)


if __name__ == "__main__":
    unittest.main()
