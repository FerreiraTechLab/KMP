import copy
import hashlib
import importlib.util
import json
from pathlib import Path
import stat
import tempfile
import unittest
import zipfile


ROOT = Path(__file__).resolve().parents[1]
SPEC = importlib.util.spec_from_file_location(
    "package_auditor", ROOT / "tools/audit-package.py"
)
AUDITOR = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(AUDITOR)


class AuditPackageTest(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.root = Path(self.temporary.name)
        self.package = self.root / "example.zip"
        self.submission_path = self.root / "submission.json"
        self.submission = {
            "schemaVersion": 1,
            "project": {"id": "example"},
            "release": {
                "revision": 1,
                "variants": [{
                    "id": "aarch64", "compatibility": {"architectures": ["aarch64"]},
                    "package": {"path": "example.zip", "sizeBytes": 1,
                                "sha256": "0" * 64},
                    "install": {"paths": ["example.sh", "example/"],
                                "userDataPaths": ["example/conf/"]},
                }],
            },
        }

    def tearDown(self):
        self.temporary.cleanup()

    def write_zip(self, entries):
        with zipfile.ZipFile(self.package, "w", zipfile.ZIP_DEFLATED) as archive:
            for name, content, mode in entries:
                info = zipfile.ZipInfo(name)
                info.create_system = 3
                info.external_attr = mode << 16
                archive.writestr(info, content)
        package = self.submission["release"]["variants"][0]["package"]
        package["sizeBytes"] = self.package.stat().st_size
        package["sha256"] = hashlib.sha256(self.package.read_bytes()).hexdigest()
        self.submission_path.write_text(json.dumps(self.submission))

    def finding_codes(self, report):
        return {finding["code"] for finding in report["findings"]}

    def test_safe_package_passes(self):
        self.write_zip([
            ("example.sh", b"#!/bin/bash\necho ok\n", stat.S_IFREG | 0o755),
            ("example/game.bin", b"data", stat.S_IFREG | 0o755),
            ("example/LICENSE", b"MIT", stat.S_IFREG | 0o644),
        ])
        report = AUDITOR.audit(self.submission_path, "aarch64")
        self.assertEqual(report["verdict"], "pass")
        self.assertEqual(report["summary"], {"errors": 0, "warnings": 0})
        self.assertEqual(report["executables"][0]["path"], "example.sh")

    def test_network_download_requires_review(self):
        self.write_zip([
            ("example.sh", b"#!/bin/bash\ncurl https://example.org/file\n",
             stat.S_IFREG | 0o755),
            ("example/LICENSE", b"MIT", stat.S_IFREG | 0o644),
        ])
        report = AUDITOR.audit(self.submission_path, "aarch64")
        self.assertEqual(report["verdict"], "review")
        self.assertIn("NETWORK_DOWNLOAD", self.finding_codes(report))

    def test_system_mutation_is_rejected(self):
        self.write_zip([
            ("example.sh", b"#!/bin/bash\ncp config.ini /etc/example.ini\n",
             stat.S_IFREG | 0o755),
            ("example/LICENSE", b"MIT", stat.S_IFREG | 0o644),
        ])
        report = AUDITOR.audit(self.submission_path, "aarch64")
        self.assertEqual(report["verdict"], "reject")
        self.assertIn("SYSTEM_MUTATION", self.finding_codes(report))

    def test_path_traversal_is_rejected(self):
        self.write_zip([
            ("example.sh", b"#!/bin/sh\n", stat.S_IFREG | 0o755),
            ("../escape", b"bad", stat.S_IFREG | 0o644),
        ])
        report = AUDITOR.audit(self.submission_path, "aarch64")
        self.assertEqual(report["verdict"], "reject")
        self.assertIn("UNSAFE_PATH", self.finding_codes(report))

    def test_symlink_is_rejected(self):
        self.write_zip([
            ("example.sh", b"#!/bin/sh\n", stat.S_IFREG | 0o755),
            ("example/link", b"/etc/passwd", stat.S_IFLNK | 0o777),
        ])
        report = AUDITOR.audit(self.submission_path, "aarch64")
        self.assertIn("SYMLINK", self.finding_codes(report))

    def test_elf_architecture_must_match_variant(self):
        header = bytearray(64)
        header[:6] = b"\x7fELF\x02\x01"
        header[18:20] = (62).to_bytes(2, "little")
        self.write_zip([
            ("example.sh", b"#!/bin/sh\n", stat.S_IFREG | 0o755),
            ("example/game", bytes(header), stat.S_IFREG | 0o755),
        ])
        report = AUDITOR.audit(self.submission_path, "aarch64")
        self.assertIn("ELF_ARCH_MISMATCH", self.finding_codes(report))

    def test_hash_mismatch_is_rejected(self):
        self.write_zip([("example.sh", b"#!/bin/sh\n", stat.S_IFREG | 0o755)])
        document = copy.deepcopy(self.submission)
        document["release"]["variants"][0]["package"]["sha256"] = "0" * 64
        self.submission_path.write_text(json.dumps(document))
        report = AUDITOR.audit(self.submission_path, "aarch64")
        self.assertIn("HASH_MISMATCH", self.finding_codes(report))


if __name__ == "__main__":
    unittest.main()
