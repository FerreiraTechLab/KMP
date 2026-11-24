import importlib.util
import json
from pathlib import Path
import tempfile
import unittest
import zipfile


ROOT = Path(__file__).resolve().parents[1]
SPEC = importlib.util.spec_from_file_location("diagnostic", ROOT / "KMP" / "diagnostic.py")
MODULE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(MODULE)


class DiagnosticTest(unittest.TestCase):
    def test_bundle_redacts_secrets_and_excludes_secret_files(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            game = root / "ports/KMP"
            config = game / "conf"
            daemon = config / "daemon"
            daemon.mkdir(parents=True)
            secret = "0123456789abcdef0123456789abcdef"
            (daemon / "rpc.secret").write_text(secret + "\n")
            (daemon / "rpc.env").write_text("KMP_ARIA2_SECRET=" + secret + "\n")
            (daemon / "aria2.log").write_text(
                "--rpc-secret=" + secret + " token=private-token password=hunter2\n")
            (game / "log.txt").write_text("normal output\n")
            manifest = game.parent / ".kmp/manifests/example.json"
            manifest.parent.mkdir(parents=True)
            manifest.write_text(json.dumps({"id": "example", "version": "1.0"}))

            output, metadata = MODULE.create_bundle(game, config, root / "exports", "0.2.28")
            self.assertEqual(len(metadata["logs"]), 2)
            with zipfile.ZipFile(output) as archive:
                self.assertEqual(set(archive.namelist()),
                                 {"diagnostic.json", "logs/kmp.log", "logs/aria2.log"})
                combined = b"".join(archive.read(name) for name in archive.namelist())
                self.assertNotIn(secret.encode(), combined)
                self.assertNotIn(b"private-token", combined)
                self.assertNotIn(b"hunter2", combined)
                self.assertIn(b"[REDACTED]", combined)
                document = json.loads(archive.read("diagnostic.json"))
                self.assertEqual(document["appVersion"], "0.2.28")
                self.assertEqual(document["installedPorts"][0]["id"], "example")
                self.assertEqual(document["installedPorts"][0]["manifestFormat"], "legacy")

    def test_catalog_and_torrent_summaries(self):
        with tempfile.TemporaryDirectory() as directory:
            config = Path(directory)
            (config / "catalog").mkdir()
            (config / "catalog/state.json").write_text(
                '{"highestSequence":6,"lastTrustedTime":"2026-10-11T21:23:27Z"}')
            (config / "catalog/active.json").write_text(
                '{"schemaVersion":3,"sequence":6,"items":[{},{}]}')
            self.assertEqual(MODULE.catalog_status(config)["acceptedSequence"], 6)
            self.assertIsNone(MODULE.catalog_status(config)["lastSyncError"])
            (config / "catalog/last-sync.json").write_text(
                '{"ok": false, "error": "nenhum head válido; https://a/: data de publicação está no futuro"}')
            status = MODULE.catalog_status(config)
            self.assertIs(status["lastSyncOk"], False)
            self.assertIn("data de publicação está no futuro", status["lastSyncError"])
        summary = MODULE.summarize_torrents([
            [{"status": "active", "totalLength": "10", "completedLength": "10"}],
            [{"status": "paused", "totalLength": "20", "completedLength": "20"}],
            [{"status": "error", "totalLength": "0", "completedLength": "0"}],
        ])
        self.assertEqual(summary["total"], 3)
        self.assertEqual(summary["seeding"], 1)
        self.assertEqual(summary["paused"], 1)
        self.assertEqual(summary["errors"], 1)

    def test_torrent_summary_reports_backend_capabilities(self):
        calls = []
        original_credentials = MODULE.rpc_credentials
        original_call = MODULE.rpc_call
        MODULE.rpc_credentials = lambda _state: ("http://127.0.0.1:1/jsonrpc", "secret")
        def fake_call(_endpoint, _secret, method, _parameters):
            calls.append(method)
            if method == "aria2.getVersion":
                return {"version": "kmp-torrentd 0.1.0", "enabledFeatures": ["BEP55"]}
            if method == "kmp.getNetworkStats":
                return {"successfulAfterHolepunchConnect": 2}
            return []
        MODULE.rpc_call = fake_call
        try:
            value = MODULE.torrent_summary(Path("/unused"))
        finally:
            MODULE.rpc_credentials = original_credentials
            MODULE.rpc_call = original_call
        self.assertEqual(value["backend"], "kmp-torrentd 0.1.0")
        self.assertEqual(value["features"], ["BEP55"])
        self.assertEqual(value["network"]["successfulAfterHolepunchConnect"], 2)
        self.assertIn("aria2.getVersion", calls)

    def test_old_torrentd_keeps_base_summary_when_network_rpc_is_missing(self):
        original_credentials = MODULE.rpc_credentials
        original_call = MODULE.rpc_call
        MODULE.rpc_credentials = lambda _state: ("http://127.0.0.1:1/jsonrpc", "secret")
        def fake_call(_endpoint, _secret, method, _parameters):
            if method == "aria2.getVersion":
                return {"version": "kmp-torrentd 0.1.0", "enabledFeatures": ["BEP55"]}
            if method == "kmp.getNetworkStats":
                raise ValueError("método não implementado")
            return []
        MODULE.rpc_call = fake_call
        try:
            value = MODULE.torrent_summary(Path("/unused"))
        finally:
            MODULE.rpc_credentials = original_credentials
            MODULE.rpc_call = original_call
        self.assertTrue(value["available"])
        self.assertEqual(value["backend"], "kmp-torrentd 0.1.0")
        self.assertEqual(value["networkError"], "ValueError")

    def test_log_tail_is_bounded(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "large.log"
            path.write_bytes(b"x" * (MODULE.MAX_LOG_BYTES + 10))
            content, truncated = MODULE.read_tail(path)
            self.assertTrue(truncated)
            self.assertEqual(len(content), MODULE.MAX_LOG_BYTES)


if __name__ == "__main__":
    unittest.main()
