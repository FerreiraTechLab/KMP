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

    def test_keeps_few_downloads_in_progress_and_adds_seed_nodes(self):
        items = [{"release": {"variants": [{"download": {"infoHash": c * 40, "torrent": "ZA==",
            "sizeBytes": 10 + index, "packageFile": c + ".zip"}}]}} for index, c in enumerate("abcd")]
        document = {"schemaVersion": 3, "items": items,
                    "extensions": {"kmp.seed-nodes": ["163.176.18.211:6881", "não é nó"]}}
        calls = []
        torrents = {"a" * 40: {"gid": "1", "completedLength": "10", "totalLength": "10"},
                    "b" * 40: {"gid": "2", "completedLength": "3", "totalLength": "11"}}
        def fake(endpoint, secret, method, params):
            calls.append((method, params))
            if method == "aria2.tellActive":
                return [{"infoHash": key, **value} for key, value in torrents.items()]
            if method in ("aria2.tellWaiting", "aria2.tellStopped"): return []
            if method == "aria2.addTorrent": return "new" + str(len(calls))
            if method == "kmp.addPeers": raise RuntimeError("aria2 não tem este método")
        original, community.rpc = community.rpc, fake
        try:
            with tempfile.TemporaryDirectory() as directory:
                root = Path(directory)
                (root / "status.json").write_text('{"infoHashes": ["%s", "%s"]}' % ("a" * 40, "b" * 40))
                catalog = root / "active.json"; catalog.write_text(__import__("json").dumps(document))
                result = community.sync(catalog, root / "packages", "http://x", "s", 1 << 30)
        finally:
            community.rpc = original
        added = [params for method, params in calls if method == "aria2.addTorrent"]
        self.assertEqual((result["added"], result["pending"]), (1, 1), "b em andamento + 1 novo; o último espera")
        self.assertEqual(len(added), 1)
        peers = [params for method, params in calls if method == "kmp.addPeers"]
        self.assertEqual(peers[0], ["2", ["163.176.18.211:6881"]])
        self.assertEqual(len(peers), 2, "o torrent em andamento e o novo recebem o nó")

if __name__ == "__main__": unittest.main()
