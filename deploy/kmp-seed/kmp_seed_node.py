#!/usr/bin/env python3
"""Keep approved KMP catalogue packages available in a public swarm."""

from __future__ import annotations

import argparse
import base64
import hashlib
import json
import os
from pathlib import Path
import secrets
import signal
import subprocess
import sys
import tempfile
import time
from urllib.error import HTTPError, URLError
from urllib.parse import quote, urljoin, urlsplit
from urllib.request import Request, build_opener, urlopen

from catalog_security import (VerificationError, enforce_monotonic,
                              load_verified_head, public_key_fingerprint,
                              save_sequence, verify_catalog)
from catalog_sync import SafeRedirects, atomic_write, discover, read_sources

USER_AGENT = "KMP-Seed-Node/1"


def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for block in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(block)
    return digest.hexdigest()


def valid_file(path: Path, size: int, digest: str) -> bool:
    try:
        return path.is_file() and path.stat().st_size == size and sha256_file(path) == digest
    except OSError:
        return False


def download_file(sources: list[str], relative: str, destination: Path,
                  size: int, digest: str) -> str:
    """Download an exact file from a trusted mirror without keeping invalid data."""
    if valid_file(destination, size, digest):
        return "cache"
    errors = []
    destination.parent.mkdir(parents=True, exist_ok=True)
    for source in sources:
        url = urljoin(source, relative)
        parsed = urlsplit(url)
        temporary = None
        try:
            descriptor, name = tempfile.mkstemp(prefix=destination.name + ".",
                                                dir=destination.parent)
            temporary = Path(name)
            with os.fdopen(descriptor, "wb") as output:
                if parsed.scheme == "file":
                    response = Path(parsed.path).open("rb")
                else:
                    request = Request(url, headers={"User-Agent": USER_AGENT})
                    response = build_opener(SafeRedirects()).open(request, timeout=30)
                    if urlsplit(response.geturl()).scheme != "https":
                        raise VerificationError("redirecionamento inseguro")
                with response:
                    total = 0
                    actual = hashlib.sha256()
                    while True:
                        block = response.read(min(1024 * 1024, size + 1 - total))
                        if not block:
                            break
                        total += len(block)
                        if total > size:
                            raise VerificationError("arquivo excede o tamanho declarado")
                        output.write(block)
                        actual.update(block)
                    output.flush()
                    os.fsync(output.fileno())
            if total != size or actual.hexdigest() != digest:
                raise VerificationError("tamanho ou SHA-256 não confere")
            os.chmod(temporary, 0o600)
            os.replace(temporary, destination)
            return source
        except (HTTPError, URLError, TimeoutError, OSError, VerificationError) as exc:
            errors.append(f"{source}: {exc}")
            if temporary is not None:
                temporary.unlink(missing_ok=True)
    raise VerificationError("nenhum mirror entregou o arquivo; " + "; ".join(errors))


def catalogue_downloads(document: dict) -> list[dict]:
    """Return unique package downloads from supported signed catalogue schemas."""
    downloads, seen = [], set()
    if document.get("schemaVersion") == 3:
        candidates = (variant["download"] for item in document["items"]
                      for variant in item["release"]["variants"])
    else:
        candidates = ({"packageFile": item["packageFile"],
                       "sizeBytes": item["sizeBytes"],
                       "sha256": item["packageSha256"],
                       "infoHash": item["infoHash"],
                       "magnet": item["magnet"],
                       "torrent": item.get("torrent")} for item in document["items"])
    for download in candidates:
        identity = download["infoHash"].lower()
        if identity not in seen:
            downloads.append(download)
            seen.add(identity)
    return downloads


class Aria2:
    def __init__(self, binary: str, root: Path, listen_port: int):
        self.binary, self.root, self.listen_port = binary, root, listen_port
        self.rpc_port = 16800 + secrets.randbelow(1000)
        self.secret = secrets.token_hex(24)
        self.process: subprocess.Popen | None = None

    def start(self) -> None:
        data = self.root / "data"
        data.mkdir(parents=True, exist_ok=True)
        session = self.root / "session.txt"
        session.touch(mode=0o600, exist_ok=True)
        if Path(self.binary).name == "kmp-torrentd":
            arguments = [self.binary, f"--rpc-listen=127.0.0.1:{self.rpc_port}",
                         f"--rpc-secret={self.secret}",
                         f"--state-dir={self.root / 'torrentd'}", f"--data-dir={data}",
                         f"--listen-port={self.listen_port}", "--upload-limit=0",
                         # O nó público só apresenta (BEP 55) peers conectados a ele ao
                         # mesmo tempo; os limites de handheld o tornariam um gargalo.
                         "--max-conns-per-torrent=200", "--half-open-per-torrent=25"]
        else:
            arguments = [self.binary, "--enable-rpc=true", "--rpc-listen-all=false",
                         f"--rpc-listen-port={self.rpc_port}", f"--rpc-secret={self.secret}",
                         f"--dir={data}", f"--input-file={session}",
                         f"--save-session={session}", "--save-session-interval=30",
                         "--force-save=true", "--continue=true", "--auto-file-renaming=false",
                         "--file-allocation=none", "--check-integrity=true",
                         "--enable-dht=true", "--enable-peer-exchange=true",
                         "--bt-enable-lpd=true", f"--listen-port={self.listen_port}",
                         f"--dht-listen-port={self.listen_port}", "--seed-ratio=0",
                         "--max-overall-upload-limit=0", "--max-concurrent-downloads=100",
                         "--console-log-level=warn", f"--log={self.root / 'aria2.log'}",
                         "--log-level=notice"]
        self.process = subprocess.Popen(arguments, stdin=subprocess.DEVNULL)
        for _ in range(50):
            if self.process.poll() is not None:
                raise RuntimeError("daemon BitTorrent encerrou durante a inicialização")
            try:
                self.call("aria2.getVersion", [])
                return
            except VerificationError:
                time.sleep(0.1)
        raise RuntimeError("RPC do daemon BitTorrent não respondeu")

    def stop(self) -> None:
        if self.process and self.process.poll() is None:
            self.process.terminate()
            try:
                self.process.wait(timeout=10)
            except subprocess.TimeoutExpired:
                self.process.kill()

    def call(self, method: str, params: list):
        payload = json.dumps({"jsonrpc": "2.0", "id": "kmp-seed", "method": method,
                              "params": ["token:" + self.secret, *params]}).encode()
        request = Request(f"http://127.0.0.1:{self.rpc_port}/jsonrpc", data=payload,
                          headers={"Content-Type": "application/json"})
        try:
            with urlopen(request, timeout=5) as response:
                result = json.loads(response.read(1024 * 1024))
        except (HTTPError, URLError, TimeoutError, OSError, json.JSONDecodeError) as exc:
            raise VerificationError("RPC do aria2 indisponível") from exc
        if "error" in result:
            raise VerificationError(result["error"].get("message", "erro no aria2"))
        return result.get("result")

    def entries(self) -> dict[str, dict]:
        keys = ["gid", "status", "infoHash", "completedLength", "uploadLength",
                "uploadSpeed", "numSeeders", "connections"]
        result = {}
        for method, params in (("aria2.tellActive", [keys]),
                               ("aria2.tellWaiting", [0, 1000, keys]),
                               ("aria2.tellStopped", [0, 1000, keys])):
            for entry in self.call(method, params) or []:
                info_hash = str(entry.get("infoHash", "")).lower()
                if info_hash:
                    result[info_hash] = entry
        return result

    def ensure_torrent(self, encoded_torrent: str, info_hash: str) -> None:
        current = self.entries().get(info_hash.lower())
        if current and current.get("status") != "error":
            if current.get("status") == "paused":
                self.call("aria2.unpause", [current["gid"]])
            return
        if current:
            self.call("aria2.removeDownloadResult", [current["gid"]])
        options = {"dir": str(self.root / "data"), "seed-ratio": "0",
                   "check-integrity": "true", "auto-file-renaming": "false"}
        self.call("aria2.addTorrent", [encoded_torrent, [], options])


class SeedNode:
    def __init__(self, args):
        self.args, self.root = args, args.root
        self.sources = read_sources(args.sources)
        self.state = self.root / "catalog-state.json"
        self.pending = self.root / "catalog-pending"
        self.active = self.root / "catalog.json"
        self.aria = Aria2(args.aria2, self.root, args.listen_port)
        self.stopping = False

    def stop(self, *_args) -> None:
        self.stopping = True

    def sync(self) -> dict:
        discovery = discover(self.sources, self.args.public_key, self.state, self.pending)
        head = load_verified_head(self.pending / "head.json",
                                  self.pending / "head.json.sig", self.args.public_key)
        enforce_monotonic(head["sequence"], self.state)
        catalog_name = f"catalog-{head['sequence']:08d}.json"
        catalog_path = self.root / "data" / catalog_name
        download_file(self.sources, "snapshots/" + catalog_name, catalog_path,
                      head["catalogSize"], head["catalogSha256"])
        raw = verify_catalog(catalog_path, head, self.args.public_key)
        atomic_write(self.active, raw, 0o600)
        document = json.loads(raw)

        torrents = []
        if head.get("catalogTorrent"):
            info_hash = head["catalogMagnet"].split("urn:btih:", 1)[1].split("&", 1)[0]
            torrents.append((head["catalogTorrent"], info_hash))
        from_swarm = []
        for download in catalogue_downloads(document):
            package = download["packageFile"]
            try:
                download_file(self.sources, "packages/" + quote(package),
                              self.root / "data" / package,
                              download["sizeBytes"], download["sha256"])
            except VerificationError:
                # Pacotes acima do limite do Git não ficam nos mirrors; o próprio
                # torrent os obtém por webseed e peers, verificando cada peça.
                from_swarm.append(package)
            torrents.append((download["torrent"], download["infoHash"]))
        for encoded, info_hash in torrents:
            self.aria.ensure_torrent(encoded, info_hash)

        fingerprint = public_key_fingerprint(self.args.public_key)
        rotation = head.get("nextKey")
        if rotation is not None:
            fingerprint = rotation["sha256"]
        save_sequence(head["sequence"], self.state, key_fingerprint=fingerprint)
        if rotation is not None:
            atomic_write(self.args.public_key,
                         base64.b64decode(rotation["publicKey"], validate=True), 0o600)

        status = {"ok": True, "sequence": head["sequence"],
                  "catalogItems": len(document["items"]),
                  "managedTorrents": len(torrents), "packagesFromSwarm": from_swarm,
                  "aria2Torrents": len(self.aria.entries()),
                  "listenPort": self.args.listen_port,
                  "updatedAt": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
                  "healthyMirrors": discovery["healthyMirrors"]}
        atomic_write(self.root / "status.json",
                     (json.dumps(status, indent=2, sort_keys=True) + "\n").encode(), 0o600)
        return status

    def run(self) -> int:
        self.root.mkdir(parents=True, exist_ok=True)
        self.aria.start()
        signal.signal(signal.SIGTERM, self.stop)
        signal.signal(signal.SIGINT, self.stop)
        try:
            while not self.stopping:
                if self.aria.process and self.aria.process.poll() is not None:
                    raise RuntimeError("aria2 encerrou inesperadamente")
                try:
                    print(json.dumps(self.sync(), ensure_ascii=False), flush=True)
                except Exception as exc:
                    print(json.dumps({"ok": False, "error": str(exc)}, ensure_ascii=False),
                          file=sys.stderr, flush=True)
                deadline = time.monotonic() + self.args.interval
                while not self.stopping and time.monotonic() < deadline:
                    time.sleep(min(1, deadline - time.monotonic()))
        finally:
            self.aria.stop()
        return 0


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--root", type=Path, required=True)
    parser.add_argument("--sources", type=Path, required=True)
    parser.add_argument("--public-key", type=Path, required=True)
    parser.add_argument("--aria2", default="aria2c")
    parser.add_argument("--listen-port", type=int, default=6881)
    parser.add_argument("--interval", type=int, default=300)
    args = parser.parse_args()
    if not 1024 <= args.listen_port <= 65535 or args.interval < 30:
        parser.error("porta ou intervalo inválido")
    return SeedNode(args).run()


if __name__ == "__main__":
    raise SystemExit(main())
