import hashlib
import importlib.util
import json
from pathlib import Path
import tempfile
import unittest
import zipfile


ROOT = Path(__file__).resolve().parents[1]
SPEC = importlib.util.spec_from_file_location("self_update", ROOT / "KMP/self_update.py")
MODULE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(MODULE)


class SelfUpdateTest(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.base = Path(self.temporary.name) / "ports"
        self.base.mkdir()
        (self.base / "KMP").mkdir()
        (self.base / "KMP/version.txt").write_text("1.0\n")
        (self.base / "KMP/game.love").write_text("old game")
        (self.base / "KMP/conf").mkdir()
        (self.base / "KMP/conf/state.json").write_text("save")
        (self.base / "KMP/diagnostics").mkdir()
        (self.base / "KMP/diagnostics/report.zip").write_text("report")
        (self.base / "KMP/peer.txt").write_text("192.168.0.1:6881")
        (self.base / "KMP.sh").write_text("#!/bin/sh\necho old\n")
        self.package = self.base / "KMP-v2.0.zip"
        with zipfile.ZipFile(self.package, "w") as archive:
            archive.writestr("KMP.sh", "#!/bin/sh\necho new\n")
            archive.writestr("KMP/version.txt", "2.0\n")
            archive.writestr("KMP/game.love", "new game")
            archive.writestr("KMP/self_update.py", "# updater")
            archive.writestr("KMP/new.txt", "new")
        self.item = {
            "id": "kmp-client", "version": "2.0", "infoHash": "a" * 40,
            "packageFile": self.package.name, "sizeBytes": self.package.stat().st_size,
            "packageSha256": hashlib.sha256(self.package.read_bytes()).hexdigest(),
            "install": {"portId": "kmp-client", "paths": ["KMP.sh", "KMP/"]},
        }

    def tearDown(self):
        self.temporary.cleanup()

    def prepare(self):
        return MODULE.prepare(self.package, self.base, self.item, ROOT / "KMP/self_update.py")

    def test_prepare_apply_and_preserve_runtime_data(self):
        pending = self.prepare()
        self.assertTrue(pending.is_file())
        self.assertTrue((self.base / ".kmp/client-updater.py").is_file())
        self.assertEqual(MODULE.apply(self.base), "2.0")
        self.assertEqual((self.base / "KMP/version.txt").read_text().strip(), "2.0")
        self.assertIn("echo new", (self.base / "KMP.sh").read_text())
        self.assertEqual((self.base / "KMP/conf/state.json").read_text(), "save")
        self.assertEqual((self.base / "KMP/diagnostics/report.zip").read_text(), "report")
        self.assertEqual((self.base / "KMP/peer.txt").read_text(), "192.168.0.1:6881")
        self.assertFalse(pending.exists())

    def test_rejects_wrong_hash_and_version(self):
        self.item["packageSha256"] = "0" * 64
        with self.assertRaisesRegex(ValueError, "SHA-256"):
            self.prepare()
        self.item["packageSha256"] = hashlib.sha256(self.package.read_bytes()).hexdigest()
        self.item["version"] = "3.0"
        with self.assertRaisesRegex(ValueError, "versão interna"):
            self.prepare()

    def test_recovery_rolls_back_or_keeps_committed_update(self):
        class PowerLoss(BaseException):
            pass

        for point in ("prepared", "backed_up", "replaced", "committed"):
            with self.subTest(point=point):
                self.tearDown()
                self.setUp()
                self.prepare()

                def checkpoint(current):
                    if current == point:
                        raise PowerLoss()

                with self.assertRaises(PowerLoss):
                    MODULE.apply(self.base, checkpoint)
                expected = "committed" if point == "committed" else "rolled_back"
                self.assertEqual(MODULE.recover(self.base), expected)
                version = "2.0" if expected == "committed" else "1.0"
                self.assertEqual((self.base / "KMP/version.txt").read_text().strip(), version)
                self.assertTrue((self.base / "KMP/conf/state.json").is_file())


if __name__ == "__main__":
    unittest.main()
