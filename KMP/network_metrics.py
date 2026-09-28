#!/usr/bin/env python3
"""Capture reproducible KMP/aria2 network measurements as JSON Lines."""

from __future__ import annotations

import argparse
from datetime import datetime, timezone
import ipaddress
import json
import os
from pathlib import Path
import time
from urllib.error import HTTPError, URLError
from urllib.request import Request, urlopen


MAX_RESPONSE = 2 * 1024 * 1024


def rpc_call(endpoint: str, secret: str, method: str, params: list | None = None):
    payload = json.dumps({"jsonrpc": "2.0", "id": "kmp-metrics", "method": method,
                          "params": ["token:" + secret, *(params or [])]}).encode()
    request = Request(endpoint, data=payload, headers={"Content-Type": "application/json"})
    try:
        with urlopen(request, timeout=5) as response:
            raw = response.read(MAX_RESPONSE + 1)
    except (HTTPError, URLError, TimeoutError, OSError) as exc:
        raise RuntimeError("RPC do aria2 indisponível") from exc
    if len(raw) > MAX_RESPONSE:
        raise RuntimeError("resposta RPC excede o limite")
    result = json.loads(raw)
    if "error" in result:
        raise RuntimeError(result["error"].get("message", "erro RPC"))
    return result.get("result")


def peer_scope(address: str) -> str:
    try:
        ip = ipaddress.ip_address(address)
    except ValueError:
        return "invalid"
    return "local" if ip.is_private or ip.is_link_local or ip.is_loopback else "remote"


def battery_percent(root: Path = Path("/sys/class/power_supply")) -> int | None:
    values = []
    if root.is_dir():
        for supply in root.iterdir():
            try:
                if (supply / "type").read_text().strip().lower() == "battery":
                    value = int((supply / "capacity").read_text().strip())
                    if 0 <= value <= 100:
                        values.append(value)
            except (OSError, ValueError):
                pass
    return min(values) if values else None


def process_metrics(pid: int | None) -> dict:
    result = {"pid": pid, "cpuTicks": None, "memoryKiB": None}
    if not pid or pid <= 0:
        return result
    try:
        fields = Path(f"/proc/{pid}/stat").read_text().split()
        result["cpuTicks"] = int(fields[13]) + int(fields[14])
        for line in Path(f"/proc/{pid}/status").read_text().splitlines():
            if line.startswith("VmRSS:"):
                result["memoryKiB"] = int(line.split()[1])
                break
    except (OSError, ValueError, IndexError):
        pass
    return result


def torrent_metrics(rpc, item: dict) -> dict:
    gid = item.get("gid")
    peers = []
    if isinstance(gid, str):
        try:
            peers = rpc("aria2.getPeers", [gid]) or []
        except RuntimeError:
            peers = []
    local = sum(peer_scope(str(peer.get("ip", ""))) == "local" for peer in peers)
    remote = sum(peer_scope(str(peer.get("ip", ""))) == "remote" for peer in peers)
    web_configured = web_active = 0
    for file in item.get("files") or []:
        for uri in file.get("uris") or []:
            if str(uri.get("uri", "")).startswith(("http://", "https://")):
                web_configured += 1
                web_active += uri.get("status") == "used"
    return {
        "gid": gid, "status": item.get("status"), "infoHash": item.get("infoHash"),
        "downloadBps": int(item.get("downloadSpeed") or 0),
        "uploadBps": int(item.get("uploadSpeed") or 0),
        "completedBytes": int(item.get("completedLength") or 0),
        "totalBytes": int(item.get("totalLength") or 0),
        "connections": int(item.get("connections") or 0),
        "seeders": int(item.get("numSeeders") or 0),
        "localPeers": local, "remotePeers": remote,
        "webSeedsConfigured": web_configured, "webSeedsActive": web_active,
    }


def capture(endpoint: str, secret: str, scenario: str, pid: int | None) -> dict:
    started = time.monotonic()
    rpc = lambda method, params=None: rpc_call(endpoint, secret, method, params)
    keys = ["gid", "status", "infoHash", "downloadSpeed", "uploadSpeed",
            "completedLength", "totalLength", "connections", "numSeeders", "files"]
    torrents = []
    for method, params in (("aria2.tellActive", [keys]),
                           ("aria2.tellWaiting", [0, 1000, keys]),
                           ("aria2.tellStopped", [0, 1000, keys])):
        torrents.extend(rpc(method, params) or [])
    global_stat = rpc("aria2.getGlobalStat") or {}
    return {
        "schemaVersion": 1,
        "capturedAt": datetime.now(timezone.utc).isoformat(timespec="seconds").replace("+00:00", "Z"),
        "scenario": scenario,
        "collectionMs": round((time.monotonic() - started) * 1000),
        "batteryPercent": battery_percent(),
        "aria2": process_metrics(pid),
        "global": {key: int(global_stat.get(key) or 0) for key in
                   ("downloadSpeed", "uploadSpeed", "numActive", "numWaiting", "numStopped")},
        "torrents": [torrent_metrics(rpc, item) for item in torrents],
    }


def append_jsonl(path: Path, document: dict) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    with path.open("a", encoding="utf-8") as handle:
        handle.write(json.dumps(document, ensure_ascii=False, sort_keys=True) + "\n")
        handle.flush()
        os.fsync(handle.fileno())


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--rpc", required=True)
    parser.add_argument("--secret", required=True)
    parser.add_argument("--scenario", required=True,
                        choices=("web-seed", "local-peer", "remote-peer", "no-seed", "nat-restricted"))
    parser.add_argument("--pid", type=int)
    parser.add_argument("--output", required=True, type=Path)
    args = parser.parse_args()
    document = capture(args.rpc, args.secret, args.scenario, args.pid)
    append_jsonl(args.output, document)
    print(json.dumps(document, ensure_ascii=False))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
