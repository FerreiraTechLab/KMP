#!/usr/bin/env python3
import importlib.util, tempfile, unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
import sys
sys.path.insert(0, str(ROOT / "KMP"))
spec = importlib.util.spec_from_file_location("community", ROOT / "KMP/community_node.py")
community = importlib.util.module_from_spec(spec); spec.loader.exec_module(community)

class CommunityNodeTests(unittest.TestCase):
    def test_deduplicates_and_orders_small_packages_first(self):
        small = {"infoHash": "a" * 40, "torrent": "ZA==", "sizeBytes": 10, "packageFile": "a.zip"}
        large = {"infoHash": "b" * 40, "torrent": "ZA==", "sizeBytes": 20, "packageFile": "b.zip"}
        doc = {"schemaVersion": 3, "items": [{"release": {"variants": [
            {"download": large}, {"download": small}, {"download": dict(small)}]}}]}
        self.assertEqual([x["infoHash"] for x in community.downloads(doc)], ["b" * 40, "a" * 40])

    def test_setting_update_preserves_daemon_settings(self):
        control_spec = importlib.util.spec_from_file_location("control", ROOT / "KMP/community_control.py")
        control = importlib.util.module_from_spec(control_spec); control_spec.loader.exec_module(control)
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "settings.conf"
            path.write_text("upload_limit=100K\ncommunity_node=0\n")
            control.write_setting(path, True, 2048)
            self.assertIn("upload_limit=100K", path.read_text())
            self.assertIn("community_node=1", path.read_text())
            self.assertIn("community_storage_mb=2048", path.read_text())

if __name__ == "__main__": unittest.main()
