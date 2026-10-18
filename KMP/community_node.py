#!/usr/bin/env python3
"""Add approved catalogue packages to the existing KMP BitTorrent daemon."""

import argparse, base64, json, re
from pathlib import Path
from urllib.request import Request, urlopen


def downloads(document):
    values = []
    if document.get("schemaVersion") == 3:
        candidates = (variant["download"] for item in document.get("items", [])
                      for variant in item.get("release", {}).get("variants", []))
    else:
        candidates = (item for item in document.get("items", []))
    seen = set()
    for value in candidates:
        info_hash = str(value.get("infoHash", "")).lower()
        torrent = value.get("torrent")
        size = int(value.get("sizeBytes", 0))
        if re.fullmatch(r"[0-9a-f]{40}", info_hash) and isinstance(torrent, str) and size > 0 and info_hash not in seen:
            values.append({"infoHash": info_hash, "torrent": torrent, "sizeBytes": size,
                           "packageFile": value.get("packageFile", "")})
            seen.add(info_hash)
    return values


def rpc(endpoint, secret, method, params):
    body = json.dumps({"jsonrpc": "2.0", "id": "kmp-community", "method": method,
                       "params": ["token:" + secret, *params]}).encode()
    request = Request(endpoint, data=body, headers={"Content-Type": "application/json"})
    with urlopen(request, timeout=10) as response:
        result = json.loads(response.read(1024 * 1024))
    if "error" in result:
        raise RuntimeError(result["error"].get("message", "erro no daemon BitTorrent"))
    return result.get("result")


def current_hashes(endpoint, secret):
    found = set()
    keys = ["infoHash"]
    for method, params in (("aria2.tellActive", [keys]),
                           ("aria2.tellWaiting", [0, 1000, keys]),
                           ("aria2.tellStopped", [0, 1000, keys])):
        for item in rpc(endpoint, secret, method, params) or []:
            value = str(item.get("infoHash", "")).lower()
            if re.fullmatch(r"[0-9a-f]{40}", value):
                found.add(value)
    return found


def sync(catalog, directory, endpoint, secret, limit_bytes):
    directory.mkdir(parents=True, exist_ok=True)
    selected, used = [], 0
    for item in sorted(downloads(json.loads(catalog.read_text())),
                       key=lambda value: (value["sizeBytes"], value["infoHash"])):
        if used + item["sizeBytes"] <= limit_bytes:
            selected.append(item); used += item["sizeBytes"]
    status_path = directory.parent / "status.json"
    try: owned = set(json.loads(status_path.read_text()).get("infoHashes", []))
    except (OSError, ValueError): owned = set()
    present, added = current_hashes(endpoint, secret), 0
    for item in selected:
        if item["infoHash"] in present:
            continue
        base64.b64decode(item["torrent"], validate=True)
        rpc(endpoint, secret, "aria2.addTorrent", [item["torrent"], [], {
            "dir": str(directory), "continue": "true", "check-integrity": "true",
            "seed-ratio": "0", "auto-file-renaming": "false"}])
        added += 1
        owned.add(item["infoHash"])
    result = {"enabled": True, "managed": len(selected), "added": added,
              "infoHashes": sorted(owned),
              "reservedBytes": used, "limitBytes": limit_bytes}
    status_path.write_text(json.dumps(result, indent=2) + "\n")
    return result


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--catalog", required=True, type=Path)
    parser.add_argument("--directory", required=True, type=Path)
    parser.add_argument("--rpc", required=True)
    parser.add_argument("--secret", required=True)
    parser.add_argument("--limit-mb", type=int, default=4096)
    args = parser.parse_args()
    if args.limit_mb < 64:
        parser.error("o limite precisa ser de pelo menos 64 MiB")
    print(json.dumps(sync(args.catalog, args.directory, args.rpc, args.secret,
                          args.limit_mb * 1024 * 1024)))


if __name__ == "__main__":
    main()
