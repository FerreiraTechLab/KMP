#!/usr/bin/env python3
"""Enable or disable community mirroring in a running KMP Client."""

import argparse, json, os, tempfile
from pathlib import Path
from community_node import rpc, sync

def write_setting(path, enabled, limit):
    values = {}
    if path.exists():
        for line in path.read_text().splitlines():
            if "=" in line:
                key, value = line.split("=", 1); values[key] = value
    values["community_node"] = "1" if enabled else "0"
    values["community_storage_mb"] = str(limit)
    path.parent.mkdir(parents=True, exist_ok=True)
    fd, name = tempfile.mkstemp(prefix="settings.", dir=path.parent)
    with os.fdopen(fd, "w") as handle:
        for key in sorted(values): handle.write(f"{key}={values[key]}\n")
        handle.flush(); os.fsync(handle.fileno())
    os.replace(name, path)

def disable(status_path, endpoint, secret):
    try: state = json.loads(status_path.read_text())
    except (OSError, ValueError): state = {}
    removed, hashes = 0, set(state.get("infoHashes", []))
    for method, params in (("aria2.tellActive", [["gid", "infoHash"]]),
                           ("aria2.tellWaiting", [0, 1000, ["gid", "infoHash"]]),
                           ("aria2.tellStopped", [0, 1000, ["gid", "infoHash"]])):
        for item in rpc(endpoint, secret, method, params) or []:
            if str(item.get("infoHash", "")).lower() in hashes:
                try: rpc(endpoint, secret, "aria2.forceRemove", [item["gid"]])
                except RuntimeError: rpc(endpoint, secret, "aria2.removeDownloadResult", [item["gid"]])
                removed += 1
    state.update({"enabled": False, "removed": removed})
    status_path.write_text(json.dumps(state, indent=2) + "\n")
    return state

def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("action", choices=("enable", "disable"))
    parser.add_argument("--settings", required=True, type=Path)
    parser.add_argument("--catalog", required=True, type=Path)
    parser.add_argument("--directory", required=True, type=Path)
    parser.add_argument("--rpc", required=True); parser.add_argument("--secret", required=True)
    parser.add_argument("--limit-mb", type=int, default=4096)
    args = parser.parse_args(); enabled = args.action == "enable"
    write_setting(args.settings, enabled, args.limit_mb)
    result = sync(args.catalog, args.directory, args.rpc, args.secret,
                  args.limit_mb * 1024 * 1024) if enabled else \
             disable(args.directory.parent / "status.json", args.rpc, args.secret)
    print(json.dumps(result))

if __name__ == "__main__": main()
