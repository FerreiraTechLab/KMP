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
        with self.assertRaisesRegex(ValueError, "já instalado"):
            module.install(self.package, self.base, self.item)
        (self.base / "example" / "user.txt").write_text("keep")
        module.uninstall(self.base, "example")
        self.assertFalse((self.base / "example.sh").exists())
        self.assertTrue((self.base / "example" / "user.txt").exists())
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


if __name__ == "__main__":
    unittest.main()
