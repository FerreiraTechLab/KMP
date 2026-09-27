#!/usr/bin/env python3
"""Build a signed KMP catalogue head from a schema-2 snapshot."""

from __future__ import annotations

import argparse
import base64
import hashlib
import json
from pathlib import Path
import shutil
import subprocess
from datetime import datetime, timedelta, timezone


def timestamp(value: datetime) -> str:
    return value.astimezone(timezone.utc).isoformat(timespec="seconds").replace("+00:00", "Z")


def sign(path: Path, key: Path, output: Path) -> bytes:
    subprocess.run(
        ["openssl", "pkeyutl", "-sign", "-rawin", "-inkey", str(key),
         "-in", str(path), "-out", str(output)],
        check=True,
    )
    return output.read_bytes()


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("catalog", type=Path)
    parser.add_argument("--private-key", required=True, type=Path)
    parser.add_argument("--magnet", required=True)
    parser.add_argument("--output", required=True, type=Path)
    parser.add_argument("--valid-days", type=int, default=30)
    args = parser.parse_args()

    raw = args.catalog.read_bytes()
    document = json.loads(raw)
    if not isinstance(document, dict) or document.get("schemaVersion") != 2:
        parser.error("o catálogo precisa usar schemaVersion 2")
    sequence = document.get("sequence")
    if not isinstance(sequence, int) or isinstance(sequence, bool) or sequence < 1:
        parser.error("sequence precisa ser um inteiro positivo")
    if not args.magnet.startswith("magnet:?xt=urn:btih:"):
        parser.error("magnet inválido")
    if not args.private_key.is_file():
        parser.error("chave privada não encontrada")

    args.output.mkdir(parents=True, exist_ok=True)
    catalog_name = f"catalog-{sequence:08d}.json"
    catalog_path = args.output / catalog_name
    shutil.copyfile(args.catalog, catalog_path)
    catalog_signature_path = args.output / (catalog_name + ".sig")
    catalog_signature = sign(catalog_path, args.private_key, catalog_signature_path)

    now = datetime.now(timezone.utc).replace(microsecond=0)
    head = {
        "schemaVersion": 1,
        "sequence": sequence,
        "catalogSize": len(raw),
        "catalogSha256": hashlib.sha256(raw).hexdigest(),
        "catalogMagnet": args.magnet,
        "catalogSignature": base64.b64encode(catalog_signature).decode("ascii"),
        "publishedAt": timestamp(now),
        "expiresAt": timestamp(now + timedelta(days=args.valid_days)),
    }
    head_path = args.output / "head.json"
    head_path.write_text(json.dumps(head, ensure_ascii=False, sort_keys=True,
                                    separators=(",", ":")) + "\n", encoding="utf-8")
    sign(head_path, args.private_key, args.output / "head.json.sig")
    print(f"release criada em {args.output} (sequência {sequence})")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
