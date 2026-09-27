import importlib.util
import json
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "KMP"))
SPEC = importlib.util.spec_from_file_location("catalog_sync", ROOT / "KMP" / "catalog_sync.py")
SYNC = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(SYNC)


class CatalogSyncTest(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.root = Path(self.temporary.name)
        self.private_key = self.root / "private.pem"
        self.public_key = self.root / "public.pem"
        subprocess.run(["openssl", "genpkey", "-algorithm", "ED25519",
                        "-out", str(self.private_key)], check=True,
                       stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        subprocess.run(["openssl", "pkey", "-in", str(self.private_key),
                        "-pubout", "-out", str(self.public_key)], check=True,
                       stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)

    def tearDown(self):
        self.temporary.cleanup()

    def release(self, name, sequence, marker=""):
        source = self.root / f"{name}.json"
        source.write_text(json.dumps({"schemaVersion": 2, "sequence": sequence,
            "generatedAt": "2026-09-26T23:00:00Z", "items": [], "marker": marker},
            separators=(",", ":")) + "\n")
        output = self.root / name
        subprocess.run(["python3", str(ROOT / "tools/catalog-release.py"), str(source),
            "--private-key", str(self.private_key), "--magnet",
            "magnet:?xt=urn:btih:" + ("a" if sequence == 7 else "b") * 40,
            "--output", str(output)], check=True, stdout=subprocess.DEVNULL)
        return output

    def test_discovers_highest_valid_mirror_and_activates(self):
        lower = self.release("lower", 7)
        higher = self.release("higher", 8)
        invalid = self.root / "invalid"
        invalid.mkdir()
        (invalid / "head.json").write_text("broken")
        (invalid / "head.json.sig").write_text("broken")
        pending = self.root / "pending"
        state = self.root / "state.json"
        result = SYNC.discover([invalid.as_uri() + "/", lower.as_uri() + "/",
                                higher.as_uri() + "/"], self.public_key, state, pending)
        self.assertEqual(result["sequence"], 8)
        active = self.root / "active.json"
        activated = SYNC.activate(pending / "head.json", pending / "head.json.sig",
            higher / "catalog-00000008.json", self.public_key, state, active)
        self.assertEqual(activated["sequence"], 8)
        self.assertEqual(json.loads(active.read_text())["sequence"], 8)
        self.assertEqual(json.loads(state.read_text())["highestSequence"], 8)

    def test_rejects_rollback(self):
        release = self.release("old", 7)
        state = self.root / "state.json"
        state.write_text('{"highestSequence":8}\n')
        with self.assertRaisesRegex(SYNC.VerificationError, "nenhum head válido"):
            SYNC.discover([release.as_uri() + "/"], self.public_key, state,
                          self.root / "pending")

    def test_rejects_conflicting_signed_heads(self):
        first = self.release("first", 8, "first")
        second = self.release("second", 8, "second")
        with self.assertRaisesRegex(SYNC.VerificationError, "conflito"):
            SYNC.discover([first.as_uri() + "/", second.as_uri() + "/"],
                          self.public_key, self.root / "state.json",
                          self.root / "pending")

    def test_sources_allow_only_https_and_file(self):
        sources = self.root / "sources.txt"
        sources.write_text("http://insecure.example/catalog\n")
        with self.assertRaisesRegex(SYNC.VerificationError, "não permitida"):
            SYNC.read_sources(sources)

    def test_download_follows_metadata_gid_and_keeps_seed(self):
        directory = self.root / "downloads"
        target = directory / "catalog-00000008.json"
        target.parent.mkdir()
        target.write_text("{}")
        calls = []
        statuses = iter([
            {"status": "complete", "followedBy": ["bbbb"]},
            {"status": "active", "seeder": "true", "totalLength": "2",
             "infoHash": "b" * 40, "files": [{"path": str(target)}]},
        ])

        def rpc(method, params):
            calls.append(method)
            if method == "aria2.addUri":
                return "aaaa"
            if method == "aria2.tellStatus":
                return next(statuses)
            self.fail(method)

        head = {"sequence": 8, "catalogMagnet":
                "magnet:?xt=urn:btih:" + "b" * 40}
        result = SYNC.download_snapshot(head, directory, rpc, sleep=lambda _: None)
        self.assertEqual(result, target)
        self.assertEqual(calls, ["aria2.addUri", "aria2.tellStatus", "aria2.tellStatus"])

    def test_download_rejects_wrong_file_name(self):
        directory = self.root / "downloads"
        wrong = directory / "unexpected.json"
        wrong.parent.mkdir()
        wrong.write_text("{}")

        def rpc(method, params):
            if method == "aria2.addUri":
                return "aaaa"
            return {"status": "complete", "totalLength": "2", "infoHash": "b" * 40,
                    "files": [{"path": str(wrong)}]}

        head = {"sequence": 8, "catalogMagnet":
                "magnet:?xt=urn:btih:" + "b" * 40}
        with self.assertRaisesRegex(SYNC.VerificationError, "nome inesperado"):
            SYNC.download_snapshot(head, directory, rpc, sleep=lambda _: None)


if __name__ == "__main__":
    unittest.main()
