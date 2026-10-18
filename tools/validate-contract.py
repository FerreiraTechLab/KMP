#!/usr/bin/env python3
"""Validate semantic invariants shared by KMP submission and catalog contracts."""

from __future__ import annotations

import argparse
import base64
import binascii
import json
from pathlib import Path
import re
import hashlib
from urllib.parse import urlparse


class ContractError(ValueError):
    pass


def bdecode(payload: bytes):
    """Decode the strict bencode subset used by v1 torrent metadata."""
    offset = 0

    def take():
        nonlocal offset
        if offset >= len(payload):
            fail("torrent truncado")
        marker = payload[offset]
        if marker == ord("i"):
            end = payload.find(b"e", offset + 1)
            if end < 0:
                fail("inteiro bencode truncado")
            raw = payload[offset + 1:end]
            if not re.fullmatch(rb"-?(0|[1-9][0-9]*)", raw):
                fail("inteiro bencode inválido")
            offset = end + 1
            return int(raw)
        if marker == ord("l"):
            offset += 1
            result = []
            while offset < len(payload) and payload[offset] != ord("e"):
                result.append(take())
            if offset >= len(payload):
                fail("lista bencode truncada")
            offset += 1
            return result
        if marker == ord("d"):
            offset += 1
            result, previous = {}, None
            while offset < len(payload) and payload[offset] != ord("e"):
                key = take()
                if not isinstance(key, bytes) or (previous is not None and key <= previous):
                    fail("dicionário bencode inválido")
                previous, result[key] = key, take()
            if offset >= len(payload):
                fail("dicionário bencode truncado")
            offset += 1
            return result
        colon = payload.find(b":", offset)
        if colon < 0 or not payload[offset:colon].isdigit():
            fail("string bencode inválida")
        size = int(payload[offset:colon])
        if payload[offset:colon].startswith(b"0") and size:
            fail("tamanho bencode inválido")
        offset = colon + 1
        end = offset + size
        if end > len(payload):
            fail("string bencode truncada")
        value, offset = payload[offset:end], end
        return value

    value = take()
    if offset != len(payload):
        fail("dados após o torrent")
    return value


def bencode(value):
    if isinstance(value, int):
        return b"i" + str(value).encode() + b"e"
    if isinstance(value, bytes):
        return str(len(value)).encode() + b":" + value
    if isinstance(value, list):
        return b"l" + b"".join(bencode(item) for item in value) + b"e"
    if isinstance(value, dict):
        return b"d" + b"".join(bencode(key) + bencode(value[key]) for key in sorted(value)) + b"e"
    fail("tipo bencode inválido")


def check_torrent(payload: bytes, download: dict, context: str) -> None:
    document = bdecode(payload)
    if not isinstance(document, dict) or not isinstance(document.get(b"info"), dict):
        fail(f"{context}: metainfo BitTorrent inválido")
    info = document[b"info"]
    if b"files" in info or info.get(b"name", b"").decode("utf-8", "replace") != download["packageFile"]:
        fail(f"{context}: torrent não contém somente o ZIP esperado")
    if info.get(b"length") != download["sizeBytes"]:
        fail(f"{context}: tamanho do torrent diverge do pacote")
    if info.get(b"private", 0) not in (0,):
        fail(f"{context}: torrent privado impede a rede DHT")
    if hashlib.sha1(bencode(info)).hexdigest() != download["infoHash"]:
        fail(f"{context}: infoHash não corresponde ao torrent")
    trackers = []
    for tier in document.get(b"announce-list", []):
        if isinstance(tier, list):
            trackers.extend(value.decode("utf-8", "replace") for value in tier if isinstance(value, bytes))
    announce = document.get(b"announce")
    if isinstance(announce, bytes):
        trackers.append(announce.decode("utf-8", "replace"))
    trackers = set(trackers)
    if len(trackers) < 2 or any(urlparse(value).scheme not in ("http", "https", "udp") for value in trackers):
        fail(f"{context}: torrent precisa de ao menos dois trackers públicos válidos")


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
            check_torrent(torrent, download, context)


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
