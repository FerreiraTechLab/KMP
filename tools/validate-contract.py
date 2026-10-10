#!/usr/bin/env python3
"""Validate semantic invariants shared by KMP submission and catalog contracts."""

from __future__ import annotations

import argparse
import base64
import binascii
import json
from pathlib import Path
import re


class ContractError(ValueError):
    pass


def fail(message: str) -> None:
    raise ContractError(message)


def root(path: str) -> str:
    return path.rstrip("/").split("/", 1)[0]


def check_install(install: dict, context: str) -> None:
    roots = {root(path) for path in install["paths"]}
    for user_path in install["userDataPaths"]:
        if root(user_path) not in roots:
            fail(f"{context}: userDataPath fora das raízes de instalação: {user_path}")


def check_compatibility(compatibility: dict, context: str) -> None:
    firmwares = compatibility.get("firmwares", {})
    overlap = set(firmwares.get("include", [])) & set(firmwares.get("exclude", []))
    if overlap:
        fail(f"{context}: firmware incluído e excluído: {sorted(overlap)[0]}")


def validate_submission(document: dict) -> None:
    variants = document["release"]["variants"]
    ids = set()
    for variant in variants:
        context = f"variante {variant['id']}"
        if variant["id"] in ids:
            fail(f"id de variante duplicado: {variant['id']}")
        ids.add(variant["id"])
        if not variant["package"]["path"].lower().endswith(".zip"):
            fail(f"{context}: pacote não é ZIP")
        check_compatibility(variant["compatibility"], context)
        check_install(variant["install"], context)


def validate_catalog(document: dict) -> None:
    item_ids, port_owners, install_roots, package_hashes = set(), {}, {}, set()
    revoked = {entry["packageSha256"] for entry in document["revocations"]
               if entry["action"] == "block-install"}
    if len(revoked) != sum(1 for entry in document["revocations"]
                           if entry["action"] == "block-install"):
        fail("revogação block-install duplicada")
    for item in document["items"]:
        item_id = item["id"]
        if item_id in item_ids:
            fail(f"id de item duplicado: {item_id}")
        item_ids.add(item_id)
        variant_ids = set()
        for variant in item["release"]["variants"]:
            variant_id = variant["id"]
            context = f"{item_id}/{variant_id}"
            if variant_id in variant_ids:
                fail(f"{item_id}: id de variante duplicado: {variant_id}")
            variant_ids.add(variant_id)
            check_compatibility(variant["compatibility"], context)
            check_install(variant["install"], context)
            port_id = variant["install"]["portId"]
            owner = port_owners.setdefault(port_id, item_id)
            if owner != item_id:
                fail(f"portId compartilhado por {owner} e {item_id}: {port_id}")
            for path in variant["install"]["paths"]:
                path_root = root(path)
                owner = install_roots.setdefault(path_root, item_id)
                if owner != item_id:
                    fail(f"raiz compartilhada por {owner} e {item_id}: {path_root}")
            download = variant["download"]
            if download["sha256"] in package_hashes:
                fail(f"SHA-256 de pacote duplicado: {download['sha256']}")
            package_hashes.add(download["sha256"])
            if download["sha256"] in revoked:
                fail(f"{context}: catálogo oferece pacote bloqueado")
            match = re.search(r"(?:^magnet:\?xt=|[?&]xt=)urn:btih:([0-9a-fA-F]{40})(?:&|$)",
                              download["magnet"])
            if not match or match.group(1).lower() != download["infoHash"]:
                fail(f"{context}: magnet não corresponde ao infoHash")
            try:
                torrent = base64.b64decode(download["torrent"], validate=True)
            except (binascii.Error, ValueError) as exc:
                raise ContractError(f"{context}: torrent não é base64 válido") from exc
            if not 1 <= len(torrent) <= 64 * 1024:
                fail(f"{context}: tamanho do torrent inválido")


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("kind", choices=("submission", "catalog"))
    parser.add_argument("files", nargs="+", type=Path)
    args = parser.parse_args()
    for path in args.files:
        try:
            document = json.loads(path.read_text(encoding="utf-8"))
            (validate_submission if args.kind == "submission" else validate_catalog)(document)
        except (OSError, json.JSONDecodeError, KeyError, TypeError, ContractError) as exc:
            parser.error(f"{path}: {exc}")
        print(f"contrato válido: {path}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
