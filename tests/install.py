import importlib.util
import json
from pathlib import Path
import tempfile
import unittest
import zipfile


spec = importlib.util.spec_from_file_location("kmp_install", "KMP/install.py")
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)


class InstallTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.base = Path(self.temp.name)
        self.package = self.base / "example.zip"
        self.item = {
            "id": "example", "version": "1", "infoHash": "a" * 40,
            "revision": 7, "variantId": "aarch64-portmaster",
            "packageFile": "example.zip", "sizeBytes": 1024,
            "install": {"portId": "example", "paths": ["example.sh", "example/"]},
        }

    def tearDown(self):
        self.temp.cleanup()

    def make_zip(self, entries):
        with zipfile.ZipFile(self.package, "w") as archive:
            for name, content in entries.items():
                archive.writestr(name, content)

    def test_install_and_manifest(self):
        self.make_zip({"example.sh": "#!/bin/sh\n", "example/data.txt": "data"})
        manifest = module.install(self.package, self.base, self.item)
        self.assertTrue((self.base / "example.sh").is_file())
        self.assertTrue((self.base / "example.sh").stat().st_mode & 0o111)
        self.assertEqual(json.loads(manifest.read_text())["files"], ["example.sh", "example/data.txt"])
        record = json.loads(manifest.read_text())
        self.assertEqual(record["revision"], 7)
        self.assertEqual(record["variantId"], "aarch64-portmaster")
        with self.assertRaisesRegex(ValueError, "já instalado"):
            module.install(self.package, self.base, self.item)
        (self.base / "example" / "user.txt").write_text("keep")
        module.uninstall(self.base, "example")
        self.assertFalse((self.base / "example.sh").exists())
        self.assertFalse((self.base / "example").exists())
        self.assertFalse((self.base / ".kmp/preserved/example").exists())
        self.assertFalse(manifest.exists())

    def test_reject_escape_without_writing(self):
        self.make_zip({"example.sh": "x", "example/file": "x", "../escape": "x"})
        with self.assertRaisesRegex(ValueError, "caminho inválido"):
            module.install(self.package, self.base, self.item)
        self.assertFalse((self.base / "example.sh").exists())

    def test_reject_other_port(self):
        self.make_zip({"example.sh": "x", "example/file": "x", "other.sh": "x"})
        with self.assertRaisesRegex(ValueError, "fora do pacote"):
            module.install(self.package, self.base, self.item)

    def test_recovers_each_interrupted_install_step(self):
        class PowerLoss(BaseException):
            pass

        for point, expected in (("journaled", "rolled_back"),
                                ("prepared", "rolled_back"),
                                ("replaced:example", "rolled_back"),
                                ("moved:example", "rolled_back"),
                                ("manifest", "committed")):
            with self.subTest(point=point), tempfile.TemporaryDirectory() as directory:
                base = Path(directory)
                package = base / "example.zip"
                with zipfile.ZipFile(package, "w") as archive:
                    archive.writestr("example.sh", "#!/bin/sh\n")
                    archive.writestr("example/data.txt", "data")

                def checkpoint(current):
                    if current == point:
                        raise PowerLoss()

                with self.assertRaises(PowerLoss):
                    module.install(package, base, self.item, checkpoint=checkpoint)
                result = module.recover(base)
                self.assertEqual(result, [("example", expected)])
                manifest = base / ".kmp/manifests/example.json"
                if expected == "committed":
                    self.assertTrue(manifest.is_file())
                    self.assertTrue((base / "example.sh").is_file())
                    self.assertTrue((base / "example/data.txt").is_file())
                else:
                    self.assertFalse(manifest.exists())
                    self.assertFalse((base / "example.sh").exists())
                    self.assertFalse((base / "example").exists())
                self.assertEqual(list((base / ".kmp/transactions").glob("*.json")), [])

    def test_normal_failure_rolls_back_immediately(self):
        self.make_zip({"example.sh": "#!/bin/sh\n", "example/data.txt": "data"})

        def checkpoint(point):
            if point.startswith("moved:"):
                raise RuntimeError("simulated")

        with self.assertRaisesRegex(RuntimeError, "simulated"):
            module.install(self.package, self.base, self.item, checkpoint=checkpoint)
        self.assertFalse((self.base / "example.sh").exists())
        self.assertFalse((self.base / "example").exists())
        self.assertEqual(module.recover(self.base), [])

    def test_rejects_package_with_wrong_sha256(self):
        self.make_zip({"example.sh": "#!/bin/sh\n", "example/data.txt": "data"})
        self.item["packageSha256"] = "0" * 64
        with self.assertRaisesRegex(ValueError, "SHA-256 do pacote não confere"):
            module.install(self.package, self.base, self.item)
        self.assertFalse((self.base / "example.sh").exists())

    def test_uninstall_removes_saves_downloads_and_p2p_tests(self):
        self.make_zip({"example.sh": "#!/bin/sh\n", "example/data.txt": "data"})
        module.install(self.package, self.base, self.item)
        save = self.base / "example/conf/save.json"
        save.parent.mkdir()
        save.write_text("progress")
        torrent = self.base / ".kmp/torrents/example/example.zip"
        torrent.parent.mkdir(parents=True)
        torrent.write_text("package")
        p2p = self.base / ".kmp/p2p-tests/example-123/example.zip"
        p2p.parent.mkdir(parents=True)
        p2p.write_text("package")
        update_cache = self.base / (".kmp/updates/example-" + "b" * 40) / "example.zip"
        update_cache.parent.mkdir(parents=True)
        update_cache.write_text("package")

        module.uninstall(self.base, "example")
        self.assertFalse((self.base / "example").exists())
        self.assertFalse((self.base / ".kmp/preserved/example").exists())
        self.assertFalse((self.base / ".kmp/torrents/example").exists())
        self.assertFalse((self.base / ".kmp/p2p-tests/example-123").exists())
        self.assertFalse(update_cache.parent.exists())
        self.assertFalse((self.base / ".kmp/manifests/example.json").exists())

    def test_update_replaces_package_and_preserves_user_files(self):
        self.make_zip({"example.sh": "#!/bin/sh\necho old\n", "example/data.txt": "old"})
        module.install(self.package, self.base, self.item)
        save = self.base / "example/conf/save.json"
        save.parent.mkdir()
        save.write_text("progress")
        self.item["version"] = "2"
        self.item["infoHash"] = "b" * 40
        self.make_zip({"example.sh": "#!/bin/sh\necho new\n", "example/data.txt": "new",
                       "example/new.txt": "added"})

        manifest = module.update(self.package, self.base, self.item)

        self.assertIn("echo new", (self.base / "example.sh").read_text())
        self.assertEqual((self.base / "example/data.txt").read_text(), "new")
        self.assertEqual((self.base / "example/new.txt").read_text(), "added")
        self.assertEqual(save.read_text(), "progress")
        self.assertEqual(json.loads(manifest.read_text())["version"], "2")
        self.assertFalse(any(self.base.glob(".kmp-backup-*")))

    def test_update_recovers_old_or_committed_version_after_power_loss(self):
        class PowerLoss(BaseException):
            pass

        points = ("journaled", "prepared", "backed_up:example",
                  "replaced:example", "merged", "manifest")
        for point in points:
            with self.subTest(point=point), tempfile.TemporaryDirectory() as directory:
                base = Path(directory)
                package = base / "example.zip"
                with zipfile.ZipFile(package, "w") as archive:
                    archive.writestr("example.sh", "#!/bin/sh\necho old\n")
                    archive.writestr("example/data.txt", "old")
                old_item = dict(self.item)
                old_item["install"] = dict(self.item["install"])
                module.install(package, base, old_item)
                save = base / "example/conf/save.json"
                save.parent.mkdir()
                save.write_text("progress")
                new_item = dict(old_item)
                new_item["version"] = "2"
                new_item["infoHash"] = "b" * 40
                with zipfile.ZipFile(package, "w") as archive:
                    archive.writestr("example.sh", "#!/bin/sh\necho new\n")
                    archive.writestr("example/data.txt", "new")

                def checkpoint(current):
                    if current == point:
                        raise PowerLoss()

                with self.assertRaises(PowerLoss):
                    module.update(package, base, new_item, checkpoint=checkpoint)
                expected = "committed" if point == "manifest" else "rolled_back"
                self.assertEqual(module.recover(base), [("example", expected)])
                record = json.loads((base / ".kmp/manifests/example.json").read_text())
                self.assertEqual(record["version"], "2" if expected == "committed" else "1")
                self.assertIn("echo " + ("new" if expected == "committed" else "old"),
                              (base / "example.sh").read_text())
                self.assertEqual(save.read_text(), "progress")

    def test_reinstall_adopts_save_directory_left_by_older_client(self):
        self.make_zip({"example.sh": "#!/bin/sh\n", "example/data.txt": "data"})
        save = self.base / "example/conf/save.json"
        save.parent.mkdir(parents=True)
        save.write_text("legacy progress")
        module.install(self.package, self.base, self.item)
        self.assertEqual(save.read_text(), "legacy progress")
        self.assertEqual((self.base / "example/data.txt").read_text(), "data")


if __name__ == "__main__":
    unittest.main()
