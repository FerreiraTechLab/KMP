import importlib.util
import json
from pathlib import Path
import subprocess
import tempfile
import unittest
from datetime import datetime, timedelta, timezone


ROOT = Path(__file__).resolve().parents[1]
SPEC = importlib.util.spec_from_file_location(
    "catalog_security", ROOT / "KMP" / "catalog_security.py"
)
SECURITY = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(SECURITY)


class CatalogSecurityTest(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.root = Path(self.temporary.name)
        self.private_key = self.root / "private.pem"
        self.public_key = self.root / "public.pem"
        subprocess.run(
            ["openssl", "genpkey", "-algorithm", "ED25519", "-out", str(self.private_key)],
            check=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
        )
        subprocess.run(
            ["openssl", "pkey", "-in", str(self.private_key), "-pubout",
             "-out", str(self.public_key)],
            check=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
        )
        self.catalog = self.root / "source.json"
        self.catalog.write_text(json.dumps({
            "schemaVersion": 2,
            "sequence": 7,
            "generatedAt": "2026-09-26T23:00:00Z",
            "items": [],
        }, separators=(",", ":")) + "\n")
        self.release = self.root / "release"
        subprocess.run([
            "python3", str(ROOT / "tools" / "catalog-release.py"), str(self.catalog),
            "--private-key", str(self.private_key),
            "--magnet", "magnet:?xt=urn:btih:" + "a" * 40,
            "--output", str(self.release),
        ], check=True, stdout=subprocess.DEVNULL)

    def tearDown(self):
        self.temporary.cleanup()

    def load_head(self):
        return SECURITY.load_verified_head(
            self.release / "head.json", self.release / "head.json.sig", self.public_key
        )

    def test_release_verifies_and_sequence_is_saved(self):
        head = self.load_head()
        raw = SECURITY.verify_catalog(
            self.release / "catalog-00000007.json", head, self.public_key
        )
        self.assertEqual(json.loads(raw)["sequence"], 7)
        state = self.root / "state.json"
        SECURITY.enforce_monotonic(7, state)
        SECURITY.save_sequence(7, state)
        SECURITY.enforce_monotonic(7, state)
        with self.assertRaisesRegex(SECURITY.VerificationError, "downgrade"):
            SECURITY.enforce_monotonic(6, state)

    def test_tampered_head_is_rejected(self):
        path = self.release / "head.json"
        path.write_bytes(path.read_bytes().replace(b'"sequence":7', b'"sequence":8'))
        with self.assertRaisesRegex(SECURITY.VerificationError, "assinatura"):
            self.load_head()

    def test_tampered_catalog_is_rejected(self):
        head = self.load_head()
        path = self.release / "catalog-00000007.json"
        path.write_bytes(path.read_bytes() + b" ")
        with self.assertRaisesRegex(SECURITY.VerificationError, "tamanho"):
            SECURITY.verify_catalog(path, head, self.public_key)

    def test_expired_head_is_rejected(self):
        document = json.loads((self.release / "head.json").read_bytes())
        after_expiry = SECURITY.parse_time(document["expiresAt"], "expiresAt") + timedelta(seconds=1)
        with self.assertRaisesRegex(SECURITY.VerificationError, "expirado"):
            SECURITY.validate_head(document, after_expiry)

    def test_future_head_is_rejected(self):
        document = json.loads((self.release / "head.json").read_bytes())
        before_publication = SECURITY.parse_time(document["publishedAt"], "publishedAt") - timedelta(hours=1)
        with self.assertRaisesRegex(SECURITY.VerificationError, "futuro"):
            SECURITY.validate_head(document, before_publication)

    def test_invalid_signed_catalog_schema_is_rejected(self):
        invalid = {"schemaVersion": 2, "sequence": 1,
                   "generatedAt": "2026-09-26T23:00:00Z", "items": [{"id": "../escape"}]}
        with self.assertRaisesRegex(SECURITY.VerificationError, "id inválido"):
            SECURITY.validate_catalog_document(invalid, 1)

    def test_authorized_next_key_is_validated(self):
        next_private = self.root / "next-private.pem"
        next_public = self.root / "next-public.pem"
        subprocess.run(["openssl", "genpkey", "-algorithm", "ED25519", "-out",
                        str(next_private)], check=True, stdout=subprocess.DEVNULL)
        subprocess.run(["openssl", "pkey", "-in", str(next_private), "-pubout", "-out",
                        str(next_public)], check=True, stdout=subprocess.DEVNULL)
        rotated = self.root / "rotated"
        subprocess.run([
            "python3", str(ROOT / "tools/catalog-release.py"), str(self.catalog),
            "--private-key", str(self.private_key), "--next-public-key", str(next_public),
            "--magnet", "magnet:?xt=urn:btih:" + "a" * 40, "--output", str(rotated),
        ], check=True, stdout=subprocess.DEVNULL)
        head = SECURITY.load_verified_head(rotated / "head.json", rotated / "head.json.sig",
                                           self.public_key)
        self.assertEqual(head["nextKey"]["effectiveAfterSequence"], 7)
        self.assertEqual(head["nextKey"]["sha256"],
                         SECURITY.public_key_fingerprint(next_public))

    def test_regressed_clock_is_rejected(self):
        state = self.root / "state.json"
        trusted = datetime(2027, 1, 2, tzinfo=timezone.utc)
        SECURITY.save_sequence(7, state, trusted)
        with self.assertRaisesRegex(SECURITY.VerificationError, "relógio"):
            SECURITY.validate_clock(trusted - timedelta(days=1), state)

    def test_package_hash_is_required_from_sequence_three(self):
        document = json.loads(self.catalog.read_text())
        document["sequence"] = 3
        document["items"] = [{
            "id": "example", "name": "Example", "version": "1", "description": "Demo",
            "license": "MIT", "sizeBytes": 1, "infoHash": "a" * 40,
            "magnet": "magnet:?xt=urn:btih:" + "a" * 40, "packageFile": "example.zip",
            "install": {"portId": "example", "paths": ["example.sh"]},
        }]
        with self.assertRaisesRegex(SECURITY.VerificationError, "packageSha256"):
            SECURITY.validate_catalog_document(document, 3)
        document["items"][0]["packageSha256"] = "b" * 64
        SECURITY.validate_catalog_document(document, 3)

    def test_catalog_v3_contract_is_accepted_and_blocked_package_is_rejected(self):
        document = json.loads((ROOT / "contract-examples/catalog-v3.json").read_text())
        SECURITY.validate_catalog_document(document, document["sequence"])
        digest = document["items"][0]["release"]["variants"][0]["download"]["sha256"]
        document["revocations"] = [{
            "packageSha256": digest, "action": "block-install", "reason": "teste",
            "publishedAt": "2026-10-10T23:30:00Z",
        }]
        with self.assertRaisesRegex(SECURITY.VerificationError, "bloqueado"):
            SECURITY.validate_catalog_document(document, document["sequence"])

    def test_catalog_release_tool_accepts_v3(self):
        output = self.root / "release-v3"
        source = ROOT / "contract-examples/catalog-v3.json"
        subprocess.run([
            "python3", str(ROOT / "tools/catalog-release.py"), str(source),
            "--private-key", str(self.private_key),
            "--magnet", "magnet:?xt=urn:btih:" + "c" * 40,
            "--output", str(output),
        ], check=True, stdout=subprocess.DEVNULL)
        head = SECURITY.load_verified_head(
            output / "head.json", output / "head.json.sig", self.public_key
        )
        raw = SECURITY.verify_catalog(
            output / "catalog-00000006.json", head, self.public_key
        )
        self.assertEqual(json.loads(raw)["schemaVersion"], 3)


if __name__ == "__main__":
    unittest.main()
