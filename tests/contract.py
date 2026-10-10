import copy
import importlib.util
import json
from pathlib import Path
import unittest


ROOT = Path(__file__).resolve().parents[1]
SPEC = importlib.util.spec_from_file_location(
    "contract_validator", ROOT / "tools" / "validate-contract.py"
)
MODULE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(MODULE)


class ContractTest(unittest.TestCase):
    def setUp(self):
        self.submission = json.loads(
            (ROOT / "contract-examples/submission-v1.json").read_text()
        )
        self.catalog = json.loads(
            (ROOT / "contract-examples/catalog-v3.json").read_text()
        )

    def test_examples_pass_semantic_validation(self):
        MODULE.validate_submission(self.submission)
        MODULE.validate_catalog(self.catalog)

    def test_user_data_must_be_inside_installed_root(self):
        document = copy.deepcopy(self.submission)
        document["release"]["variants"][0]["install"]["userDataPaths"] = ["other/save/"]
        with self.assertRaisesRegex(MODULE.ContractError, "fora das raízes"):
            MODULE.validate_submission(document)

    def test_magnet_must_match_info_hash(self):
        document = copy.deepcopy(self.catalog)
        document["items"][0]["release"]["variants"][0]["download"]["infoHash"] = "c" * 40
        with self.assertRaisesRegex(MODULE.ContractError, "magnet não corresponde"):
            MODULE.validate_catalog(document)

    def test_blocked_package_cannot_be_offered(self):
        document = copy.deepcopy(self.catalog)
        digest = document["items"][0]["release"]["variants"][0]["download"]["sha256"]
        document["revocations"] = [{
            "packageSha256": digest,
            "action": "block-install",
            "reason": "teste",
            "publishedAt": "2026-10-10T23:30:00Z",
        }]
        with self.assertRaisesRegex(MODULE.ContractError, "pacote bloqueado"):
            MODULE.validate_catalog(document)


if __name__ == "__main__":
    unittest.main()
