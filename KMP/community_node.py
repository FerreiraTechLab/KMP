#!/usr/bin/env python3
"""Add approved catalogue packages to the existing KMP BitTorrent daemon."""

import argparse, base64, json, re
from pathlib import Path
from urllib.request import Request, urlopen

# Um console novo pegava todos os ports de uma vez e esgotava a banda e a RAM; o nó
# comunitário mantém poucos downloads em andamento e completa o resto nas próximas aberturas.
MAX_IN_PROGRESS = 2
SEED_NODE = re.compile(r"^(25[0-5]|2[0-4]\d|1?\d?\d)(\.(25[0-5]|2[0-4]\d|1?\d?\d)){3}:\d{1,5}$")


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


def seed_nodes(document):
    nodes = (document.get("extensions") or {}).get("kmp.seed-nodes") or []
    return [node for node in nodes if isinstance(node, str) and SEED_NODE.match(node)][:16]


def current_torrents(endpoint, secret):
    found = {}
    keys = ["gid", "infoHash", "completedLength", "totalLength"]
    for method, params in (("aria2.tellActive", [keys]),
                           ("aria2.tellWaiting", [0, 1000, keys]),
                           ("aria2.tellStopped", [0, 1000, keys])):
        for item in rpc(endpoint, secret, method, params) or []:
            value = str(item.get("infoHash", "")).lower()
            if re.fullmatch(r"[0-9a-f]{40}", value):
                total = int(item.get("totalLength") or 0)
                found[value] = {"gid": item.get("gid"),
                                "complete": total > 0 and int(item.get("completedLength") or 0) >= total}
    return found


def add_peers(endpoint, secret, gid, nodes):
    # Itens com torrent embutido ignoram os x.pe do magnet; o aria2 não tem kmp.addPeers.
    if not nodes or not gid:
        return
    try: rpc(endpoint, secret, "kmp.addPeers", [gid, nodes])
    except (OSError, RuntimeError): pass


def sync(catalog, directory, endpoint, secret, limit_bytes):
    directory.mkdir(parents=True, exist_ok=True)
    selected, used = [], 0
    document = json.loads(catalog.read_text())
    nodes = seed_nodes(document)
    for item in sorted(downloads(document),
                       key=lambda value: (value["sizeBytes"], value["infoHash"])):
        if used + item["sizeBytes"] <= limit_bytes:
            selected.append(item); used += item["sizeBytes"]
    status_path = directory.parent / "status.json"
    try: owned = set(json.loads(status_path.read_text()).get("infoHashes", []))
    except (OSError, ValueError): owned = set()
    present, added, pending = current_torrents(endpoint, secret), 0, 0
    in_progress = [value for key, value in present.items() if key in owned and not value["complete"]]
    for value in in_progress:
        add_peers(endpoint, secret, value["gid"], nodes)
    for item in selected:
        if item["infoHash"] in present:
            continue
        if len(in_progress) >= MAX_IN_PROGRESS:
            pending += 1
            continue
        base64.b64decode(item["torrent"], validate=True)
        gid = rpc(endpoint, secret, "aria2.addTorrent", [item["torrent"], [], {
            "dir": str(directory), "continue": "true", "check-integrity": "true",
            "seed-ratio": "0", "auto-file-renaming": "false"}])
        add_peers(endpoint, secret, gid, nodes)
        in_progress.append({"gid": gid, "complete": False})
        added += 1
        owned.add(item["infoHash"])
    result = {"enabled": True, "managed": len(selected), "added": added, "pending": pending,
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
