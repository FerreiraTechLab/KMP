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


if __name__ == "__main__":
    unittest.main()
