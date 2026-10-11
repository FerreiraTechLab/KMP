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

    def test_log_tail_is_bounded(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "large.log"
            path.write_bytes(b"x" * (MODULE.MAX_LOG_BYTES + 10))
            content, truncated = MODULE.read_tail(path)
            self.assertTrue(truncated)
            self.assertEqual(len(content), MODULE.MAX_LOG_BYTES)


if __name__ == "__main__":
    unittest.main()
