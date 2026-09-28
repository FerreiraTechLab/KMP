#!/usr/bin/env python3
"""Discover and atomically activate signed KMP catalogue snapshots."""

from __future__ import annotations

import argparse
import base64
import json
import os
from pathlib import Path
import shutil
import sys
import tempfile
import time
import re
from datetime import datetime, timezone
from urllib.parse import urljoin, urlsplit
from urllib.request import HTTPRedirectHandler, Request, build_opener
from urllib.error import HTTPError, URLError

from catalog_security import (
    MAX_CATALOG_BYTES,
    MAX_HEAD_BYTES,
    VerificationError,
    enforce_monotonic,
    load_verified_head,
    public_key_fingerprint,
    save_sequence,
    validate_clock,
    verify_catalog,
)


class SafeRedirects(HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        if urlsplit(newurl).scheme != "https":
            raise HTTPError(newurl, code, "redirecionamento inseguro", headers, fp)
        return super().redirect_request(req, fp, code, msg, headers, newurl)


def atomic_write(path: Path, data: bytes, mode: int = 0o644) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    descriptor, name = tempfile.mkstemp(prefix=path.name + ".", dir=path.parent)
    try:
        with os.fdopen(descriptor, "wb") as handle:
            handle.write(data)
            handle.flush()
            os.fsync(handle.fileno())
        os.chmod(name, mode)
        os.replace(name, path)
    except BaseException:
        try:
            os.unlink(name)
        except FileNotFoundError:
            pass
        raise


def read_sources(path: Path) -> list[str]:
    sources = []
    for line in path.read_text(encoding="utf-8").splitlines():
        source = line.strip()
        if not source or source.startswith("#"):
            continue
        parsed = urlsplit(source)
        if parsed.scheme not in {"https", "file"}:
            raise VerificationError(f"fonte não permitida: {source}")
        if parsed.scheme == "https" and (not parsed.netloc or parsed.username or parsed.password):
            raise VerificationError(f"fonte HTTPS inválida: {source}")
        sources.append(source.rstrip("/") + "/")
    if not sources:
        raise VerificationError("nenhuma fonte de catálogo configurada")
    return sources


def fetch(source: str, name: str, limit: int, timeout: float = 8.0) -> bytes:
    url = urljoin(source, name)
    parsed = urlsplit(url)
    if parsed.scheme == "file":
        path = Path(parsed.path)
        if not path.is_file() or path.stat().st_size > limit:
            raise VerificationError(f"resposta inválida em {source}")
        data = path.read_bytes()
    else:
        opener = build_opener(SafeRedirects())
        request = Request(url, headers={"User-Agent": "KDownloader-PM/0.2"})
        try:
            with opener.open(request, timeout=timeout) as response:
                if urlsplit(response.geturl()).scheme != "https":
                    raise VerificationError("resposta redirecionada para protocolo inseguro")
                declared = response.headers.get("Content-Length")
                if declared and int(declared) > limit:
                    raise VerificationError("resposta excede o limite")
                data = response.read(limit + 1)
        except (HTTPError, URLError, TimeoutError, ValueError, OSError) as exc:
            raise VerificationError(f"falha ao consultar {source}") from exc
    if not data or len(data) > limit:
        raise VerificationError(f"resposta inválida em {source}")
    return data


def verify_candidate(head_bytes: bytes, signature: bytes, public_key: Path,
                     temporary: Path) -> dict:
    head_path = temporary / "head.json"
    signature_path = temporary / "head.json.sig"
    head_path.write_bytes(head_bytes)
    signature_path.write_bytes(signature)
    return load_verified_head(head_path, signature_path, public_key)


def discover(sources: list[str], public_key: Path, state_path: Path,
             pending_dir: Path) -> dict:
    discovery_started = time.monotonic()
    validate_clock(datetime.now(timezone.utc), state_path)
    candidates = []
    errors = []
    with tempfile.TemporaryDirectory(prefix="kmp-heads-") as directory:
        temporary = Path(directory)
        for index, source in enumerate(sources):
            try:
                head_bytes = fetch(source, "head.json", MAX_HEAD_BYTES)
                signature = fetch(source, "head.json.sig", 1024)
                candidate_dir = temporary / str(index)
                candidate_dir.mkdir()
                head = verify_candidate(head_bytes, signature, public_key, candidate_dir)
                enforce_monotonic(head["sequence"], state_path)
                candidates.append((head["sequence"], head_bytes, signature, head, source))
            except VerificationError as exc:
                errors.append(f"{source}: {exc}")
    if not candidates:
        raise VerificationError("nenhum head válido; " + "; ".join(errors))
    highest = max(candidate[0] for candidate in candidates)
    winners = [candidate for candidate in candidates if candidate[0] == highest]
    identities = {(candidate[1], candidate[2]) for candidate in winners}
    if len(identities) != 1:
        raise VerificationError(f"conflito entre heads assinados na sequência {highest}")
    _, head_bytes, signature, head, source = winners[0]
    atomic_write(pending_dir / "head.json", head_bytes)
    atomic_write(pending_dir / "head.json.sig", signature)
    return {"sequence": head["sequence"], "magnet": head["catalogMagnet"],
            "source": source, "head": str(pending_dir / "head.json"),
            "healthyMirrors": len(candidates), "mirrorErrors": errors,
            "discoveryMs": round((time.monotonic() - discovery_started) * 1000)}


def activate(head_path: Path, signature_path: Path, catalog_path: Path,
             public_key: Path, state_path: Path, active_path: Path) -> dict:
    now = datetime.now(timezone.utc)
    validate_clock(now, state_path)
    head = load_verified_head(head_path, signature_path, public_key)
    enforce_monotonic(head["sequence"], state_path)
    raw = verify_catalog(catalog_path, head, public_key)
    atomic_write(active_path, raw)
    fingerprint = public_key_fingerprint(public_key)
    rotated = False
    rotation = head.get("nextKey")
    if rotation is not None:
        key_data = base64.b64decode(rotation["publicKey"], validate=True)
        atomic_write(public_key, key_data, 0o600)
        fingerprint = rotation["sha256"]
        rotated = True
    save_sequence(head["sequence"], state_path, now, fingerprint)
    return {"sequence": head["sequence"], "catalog": str(active_path),
            "keyRotated": rotated}


def rpc_client(endpoint: str, secret: str):
    if not re.fullmatch(r"http://127\.0\.0\.1:[0-9]+/jsonrpc", endpoint):
        raise VerificationError("endpoint RPC inválido")
    if not re.fullmatch(r"[0-9a-f]{32,128}", secret):
        raise VerificationError("segredo RPC inválido")

    def call(method: str, params: list):
        if not re.fullmatch(r"aria2\.[A-Za-z]+", method):
            raise VerificationError("método RPC inválido")
        payload = json.dumps({"jsonrpc": "2.0", "id": "kmp-catalog", "method": method,
                              "params": ["token:" + secret, *params]}).encode()
        request = Request(endpoint, data=payload, headers={"Content-Type": "application/json"})
        try:
            with build_opener().open(request, timeout=5) as response:
                result = json.loads(response.read(1024 * 1024 + 1))
        except (HTTPError, URLError, TimeoutError, OSError, json.JSONDecodeError) as exc:
            raise VerificationError("falha no RPC do aria2") from exc
        if "error" in result:
            raise VerificationError(str(result["error"].get("message", "erro no aria2")))
        return result.get("result")
    return call


def download_snapshot(head: dict, directory: Path, rpc, timeout: int = 300,
                      sleep=time.sleep) -> Path:
    directory.mkdir(parents=True, exist_ok=True)
    expected_name = f"catalog-{head['sequence']:08d}.json"
    match = re.search(r"(?:^magnet:\?xt=|[?&]xt=)urn:btih:([0-9a-fA-F]{40})(?:&|$)",
                      head["catalogMagnet"])
    if not match:
        raise VerificationError("infoHash ausente no magnet do catálogo")
    expected_hash = match.group(1).lower()
    options = {
        "dir": str(directory), "continue": "true", "check-integrity": "true",
        "auto-file-renaming": "false", "seed-ratio": "0",
    }
    if head.get("catalogTorrent"):
        gid = rpc("aria2.addTorrent", [head["catalogTorrent"], [], options])
    else:
        gid = rpc("aria2.addUri", [[head["catalogMagnet"]], options])
    if not isinstance(gid, str) or not re.fullmatch(r"[0-9a-fA-F]+", gid):
        raise VerificationError("aria2 não iniciou o catálogo")
    deadline = time.monotonic() + timeout
    keys = ["status", "totalLength", "completedLength", "errorMessage",
            "infoHash", "seeder", "files", "followedBy"]
    while time.monotonic() < deadline:
        status = rpc("aria2.tellStatus", [gid, keys])
        if not isinstance(status, dict):
            raise VerificationError("estado inválido do aria2")
        followed = status.get("followedBy")
        if isinstance(followed, list) and followed:
            gid = followed[0]
            sleep(0.2)
            continue
        phase = status.get("status")
        if phase == "error" or phase == "removed":
            raise VerificationError(str(status.get("errorMessage") or "download interrompido"))
        total = int(status.get("totalLength") or 0)
        if total > MAX_CATALOG_BYTES:
            rpc("aria2.forceRemove", [gid])
            raise VerificationError("torrent do catálogo excede o limite")
        complete = phase == "complete" or (phase == "active" and status.get("seeder") == "true")
        if complete:
            if str(status.get("infoHash", "")).lower() != expected_hash:
                raise VerificationError("infoHash baixado não confere")
            files = status.get("files")
            if not isinstance(files, list) or len(files) != 1:
                raise VerificationError("torrent do catálogo precisa conter um arquivo")
            downloaded = Path(str(files[0].get("path", "")))
            expected = directory / expected_name
            try:
                if downloaded.resolve() != expected.resolve():
                    raise VerificationError("nome inesperado no torrent do catálogo")
            except OSError as exc:
                raise VerificationError("caminho inválido no torrent do catálogo") from exc
            return downloaded
        sleep(1)
    rpc("aria2.forceRemove", [gid])
    raise VerificationError("tempo esgotado ao baixar o catálogo")


def sync_catalog(sources_path: Path, public_key: Path, state_path: Path,
                 pending_dir: Path, download_dir: Path, active_path: Path,
                 endpoint: str, secret: str) -> dict:
    discovered = discover(read_sources(sources_path), public_key, state_path, pending_dir)
    head = load_verified_head(pending_dir / "head.json", pending_dir / "head.json.sig",
                              public_key)
    cached_path = download_dir / f"catalog-{head['sequence']:08d}.json"
    try:
        verify_catalog(cached_path, head, public_key)
        catalog_path = cached_path
    except VerificationError:
        catalog_path = download_snapshot(head, download_dir, rpc_client(endpoint, secret))
    activated = activate(pending_dir / "head.json", pending_dir / "head.json.sig",
                         catalog_path, public_key, state_path, active_path)
    return {**discovered, **activated}


def catalogue_status(sources_path: Path, public_key: Path, state_path: Path,
                     pending_dir: Path, active_path: Path) -> dict:
    result = {"configured": False, "verified": False, "sequence": 0,
              "mirrors": 0, "healthyMirrors": 0, "mirrorStatus": [],
              "fingerprint": "", "expiresAt": "",
              "active": active_path.is_file()}
    if not sources_path.is_file() or not public_key.is_file():
        return result
    result["configured"] = True
    sources = read_sources(sources_path)
    result["mirrors"] = len(sources)
    digest = public_key_fingerprint(public_key).upper()
    result["fingerprint"] = ":".join(digest[index:index + 4]
                                      for index in range(0, 32, 4))
    if state_path.is_file():
        try:
            state = json.loads(state_path.read_bytes())
            sequence = state.get("highestSequence", 0)
            if isinstance(sequence, int) and not isinstance(sequence, bool) and sequence >= 0:
                result["sequence"] = sequence
        except (OSError, json.JSONDecodeError):
            pass
    head_path = pending_dir / "head.json"
    signature_path = pending_dir / "head.json.sig"
    if head_path.is_file() and signature_path.is_file():
        try:
            validate_clock(datetime.now(timezone.utc), state_path)
            head = load_verified_head(head_path, signature_path, public_key)
            result["verified"] = True
            result["sequence"] = max(result["sequence"], head["sequence"])
            result["expiresAt"] = head["expiresAt"]
        except VerificationError:
            # A cached head signed by the previous key is expected immediately
            # after rotation. The active snapshot remains available.
            pass
    with tempfile.TemporaryDirectory(prefix="kmp-mirror-status-") as directory:
        temporary = Path(directory)
        for index, source in enumerate(sources):
            healthy = False
            message = "ok"
            try:
                candidate = temporary / str(index)
                candidate.mkdir()
                head = verify_candidate(fetch(source, "head.json", MAX_HEAD_BYTES),
                                        fetch(source, "head.json.sig", 1024),
                                        public_key, candidate)
                enforce_monotonic(head["sequence"], state_path)
                healthy = True
                result["healthyMirrors"] += 1
            except VerificationError as exc:
                message = str(exc)
            result["mirrorStatus"].append({"source": source, "healthy": healthy,
                                            "message": message})
    return result


def main() -> int:
    parser = argparse.ArgumentParser()
    subparsers = parser.add_subparsers(dest="command", required=True)
    discover_parser = subparsers.add_parser("discover")
    discover_parser.add_argument("--sources", required=True, type=Path)
    discover_parser.add_argument("--public-key", required=True, type=Path)
    discover_parser.add_argument("--state", required=True, type=Path)
    discover_parser.add_argument("--pending", required=True, type=Path)
    activate_parser = subparsers.add_parser("activate")
    activate_parser.add_argument("--head", required=True, type=Path)
    activate_parser.add_argument("--head-signature", required=True, type=Path)
    activate_parser.add_argument("--catalog", required=True, type=Path)
    activate_parser.add_argument("--public-key", required=True, type=Path)
    activate_parser.add_argument("--state", required=True, type=Path)
    activate_parser.add_argument("--active", required=True, type=Path)
    sync_parser = subparsers.add_parser("sync")
    sync_parser.add_argument("--sources", required=True, type=Path)
    sync_parser.add_argument("--public-key", required=True, type=Path)
    sync_parser.add_argument("--state", required=True, type=Path)
    sync_parser.add_argument("--pending", required=True, type=Path)
    sync_parser.add_argument("--downloads", required=True, type=Path)
    sync_parser.add_argument("--active", required=True, type=Path)
    sync_parser.add_argument("--rpc", required=True)
    sync_parser.add_argument("--secret", required=True)
    status_parser = subparsers.add_parser("status")
    status_parser.add_argument("--sources", required=True, type=Path)
    status_parser.add_argument("--public-key", required=True, type=Path)
    status_parser.add_argument("--state", required=True, type=Path)
    status_parser.add_argument("--pending", required=True, type=Path)
    status_parser.add_argument("--active", required=True, type=Path)
    args = parser.parse_args()
    try:
        if args.command == "discover":
            result = discover(read_sources(args.sources), args.public_key,
                              args.state, args.pending)
        elif args.command == "activate":
            result = activate(args.head, args.head_signature, args.catalog,
                              args.public_key, args.state, args.active)
        elif args.command == "sync":
            result = sync_catalog(args.sources, args.public_key, args.state,
                                  args.pending, args.downloads, args.active,
                                  args.rpc, args.secret)
        else:
            result = catalogue_status(args.sources, args.public_key, args.state,
                                      args.pending, args.active)
    except (VerificationError, OSError) as exc:
        print(json.dumps({"ok": False, "error": str(exc)}, ensure_ascii=False))
        return 1
    print(json.dumps({"ok": True, **result}, ensure_ascii=False))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
