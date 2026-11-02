#!/usr/bin/env python3

import hashlib
import importlib.util
import json
from pathlib import Path
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "KMP"))
SPEC = importlib.util.spec_from_file_location(
    "kmp_seed_node", ROOT / "deploy" / "kmp-seed" / "kmp_seed_node.py")
MODULE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(MODULE)


class SeedNodeTests(unittest.TestCase):
    def test_download_file_rejects_bad_mirror_and_uses_next(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            bad, good = root / "bad", root / "good"
            bad.mkdir()
            good.mkdir()
            (bad / "package.zip").write_bytes(b"wrong")
            payload = b"approved package"
            (good / "package.zip").write_bytes(payload)
            destination = root / "result" / "package.zip"
            source = MODULE.download_file(
                [bad.as_uri() + "/", good.as_uri() + "/"], "package.zip", destination,
                len(payload), hashlib.sha256(payload).hexdigest())
            self.assertEqual(source, good.as_uri() + "/")
            self.assertEqual(destination.read_bytes(), payload)

    def test_catalogue_downloads_deduplicates_variants(self):
        download = {"packageFile": "port.zip", "sizeBytes": 1, "sha256": "a" * 64,
                    "infoHash": "b" * 40, "magnet": "magnet:?xt=urn:btih:" + "b" * 40,
                    "torrent": "ZA=="}
        document = {"schemaVersion": 3, "items": [{"release": {"variants": [
            {"download": download}, {"download": dict(download)}]}}]}
        self.assertEqual(MODULE.catalogue_downloads(document), [download])

    @staticmethod
    def torrent(length=1000, extra=None):
        info = {b"length": length, b"name": b"game.zip", b"piece length": 16384, b"pieces": b"x" * 20}
        return MODULE.bencode({b"announce": b"udp://tracker.example/announce", b"info": info, **(extra or {})})

    def test_submission_torrent_keeps_infohash_and_drops_untrusted_webseeds(self):
        release = b"https://github.com/dev/KMP-catalog/releases/download/kmp-seed-x/game.zip"
        payload = self.torrent(extra={b"url-list": [release, b"http://169.254.169.254/latest/meta-data"]})
        info_hash, length, torrent = MODULE.sanitize_submission_torrent(payload, 2000)
        document, _ = MODULE.bdecode(torrent)
        self.assertEqual(length, 1000)
        self.assertEqual(document[b"url-list"], [release])
        self.assertEqual(info_hash, hashlib.sha1(MODULE.bencode(document[b"info"])).hexdigest())
        with self.assertRaisesRegex(MODULE.VerificationError, "limite"):
            MODULE.sanitize_submission_torrent(payload, 999)
        multi = MODULE.bencode({b"info": {b"files": [], b"name": b"x", b"piece length": 1, b"pieces": b""}})
        with self.assertRaisesRegex(MODULE.VerificationError, "exatamente um arquivo"):
            MODULE.sanitize_submission_torrent(multi, 2000)

    def test_submission_eligibility_uses_trusted_authors_or_label(self):
        policy = {"trustedAuthors": ["wesleiferreira98"], "label": "semear"}
        self.assertTrue(MODULE.submission_eligible({"user": {"login": "wesleiferreira98"}}, policy))
        self.assertTrue(MODULE.submission_eligible(
            {"user": {"login": "outro"}, "labels": [{"name": "semear"}]}, policy))
        self.assertFalse(MODULE.submission_eligible({"user": {"login": "outro"}, "labels": []}, policy))
        self.assertFalse(MODULE.submission_eligible(
            {"user": {"login": "outro"}, "labels": [{}]}, {"trustedAuthors": []}))

    def test_submission_seeder_adds_eligible_pulls_and_cleans_closed_ones(self):
        class FakeAria:
            def __init__(self): self.added, self.removed, self.listed = [], [], {}
            def ensure_torrent(self, encoded, info_hash, directory):
                self.added.append((info_hash, directory))
                self.listed[info_hash] = {"gid": "g-" + info_hash[:4], "dir": str(directory)}
            def entries(self): return dict(self.listed)
            def remove(self, gid):
                self.removed.append(gid)
                self.listed = {k: v for k, v in self.listed.items() if v["gid"] != gid}

        with tempfile.TemporaryDirectory() as directory:
            aria = FakeAria()
            seeder = MODULE.SubmissionSeeder(aria, Path(directory), "Owner/KMP-catalog", "https://policy")
            payload = self.torrent()
            pulls = [{"number": 3, "user": {"login": "wesleiferreira98"}, "head": {"sha": "abc"}},
                     {"number": 4, "user": {"login": "estranho"}, "labels": [], "head": {"sha": "def"}}]
            responses = {
                "https://policy": json.dumps({"trustedAuthors": ["wesleiferreira98"], "label": "semear",
                                              "maxPackageBytes": 4096, "maxTotalBytes": 8192}).encode(),
                "https://api.github.com/repos/Owner/KMP-catalog/pulls?state=open&per_page=50": None,
                "https://api.github.com/repos/Owner/KMP-catalog/pulls/3/files?per_page=100": json.dumps([
                    {"filename": "submissions/game/1.0/torrents/game.torrent", "status": "added",
                     "raw_url": "https://raw/game.torrent"},
                    {"filename": "submissions/game/1.0/submission.json", "status": "added",
                     "raw_url": "https://raw/submission.json"}]).encode(),
                "https://raw/game.torrent": payload,
            }
            tree, tree_fails, requested = [], False, []
            def fetch(url, limit, api=False):
                requested.append(url)
                if url.endswith("per_page=50"): return json.dumps(pulls).encode()
                if "/git/trees/" in url:
                    if tree_fails: raise MODULE.URLError("API indisponível")
                    return json.dumps({"tree": tree}).encode()
                if "/git/blobs/" in url:
                    return json.dumps({"content": __import__("base64").b64encode(payload).decode()}).encode()
                return responses[url]
            seeder.fetch = fetch
            status = seeder.sync(set())
            info_hash = next(iter(status["submissions"]))
            self.assertEqual(status["submissions"][info_hash]["pull"], 3)
            self.assertEqual(aria.added, [(info_hash, Path(directory) / "submissions" / info_hash)])
            self.assertFalse(any("pulls/4" in url for url in requested))
            (Path(directory) / "submissions" / info_hash).mkdir(parents=True)

            # Mesclado: o PR fecha, mas a submissão segue na branch principal até a promoção.
            pulls = []
            tree = [{"type": "blob", "path": "submissions/game/1.0/torrents/game.torrent", "sha": "b1"}]
            status = seeder.sync(set())
            self.assertEqual(status["submissions"][info_hash]["merged"], tree[0]["path"])
            self.assertEqual(aria.removed, [])

            # Uma falha na listagem nunca apaga pacotes.
            tree_fails = True
            status = seeder.sync(set())
            self.assertEqual(aria.removed, [])
            self.assertTrue(status["errors"])

            # Promovida e removida de submissions/: aí sim o torrent sai.
            tree, tree_fails = [], False
            seeder.sync(set())
            self.assertEqual(aria.removed, ["g-" + info_hash[:4]])
            self.assertFalse((Path(directory) / "submissions" / info_hash).exists())


if __name__ == "__main__":
    unittest.main()
