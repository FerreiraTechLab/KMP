#!/usr/bin/env python3
"""Dispatch catalogue validation by schemaVersion during the v2/v3 migration."""

from __future__ import annotations

import argparse
import importlib.util
import json
from pathlib import Path

from jsonschema import Draft202012Validator, FormatChecker


ROOT = Path(__file__).resolve().parents[1]
SCHEMAS = {
    2: ROOT / "schemas/catalog-v2.schema.json",
    3: ROOT / "schemas/catalog-v3.schema.json",
}


def contract_module():
    spec = importlib.util.spec_from_file_location(
        "contract_validator", ROOT / "tools/validate-contract.py"
    )
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def validate(path: Path) -> int:
    document = json.loads(path.read_text(encoding="utf-8"))
    version = document.get("schemaVersion") if isinstance(document, dict) else None
    schema_path = SCHEMAS.get(version)
    if schema_path is None:
        raise ValueError(f"schemaVersion incompatível: {version!r}")
    schema = json.loads(schema_path.read_text(encoding="utf-8"))
    Draft202012Validator.check_schema(schema)
    errors = sorted(
        Draft202012Validator(schema, format_checker=FormatChecker()).iter_errors(document),
        key=lambda error: list(error.absolute_path),
    )
    if errors:
        error = errors[0]
        location = "/".join(str(part) for part in error.absolute_path) or "<raiz>"
        raise ValueError(f"{location}: {error.message}")
    if version == 3:
        contract_module().validate_catalog(document)
    return version


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("files", nargs="+", type=Path)
    args = parser.parse_args()
    for path in args.files:
        try:
            version = validate(path)
        except (OSError, json.JSONDecodeError, ValueError) as exc:
            parser.error(f"{path}: {exc}")
        print(f"catálogo v{version} válido: {path}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
