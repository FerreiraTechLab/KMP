#!/usr/bin/env python3
"""Pause completed aria2 torrents below the configured battery threshold."""

from __future__ import annotations

import argparse
import json
import os
from pathlib import Path
import time
from urllib.request import Request, urlopen


def battery_percent(power_root: Path = Path("/sys/class/power_supply")) -> int | None:
    values = []
    if not power_root.is_dir():
        return None
    for supply in power_root.iterdir():
        try:
            kind = (supply / "type").read_text().strip().lower()
            if kind != "battery":
                continue
            value = int((supply / "capacity").read_text().strip())
            if 0 <= value <= 100:
                values.append(value)
        except (OSError, ValueError):
            continue
    return min(values) if values else None


class AriaRpc:
    def __init__(self, endpoint: str, secret: str):
        self.endpoint = endpoint
        self.secret = secret

    def call(self, method: str, params: list | None = None):
        payload = json.dumps({
            "jsonrpc": "2.0", "id": "kmp-battery", "method": method,
            "params": ["token:" + self.secret, *(params or [])],
        }).encode()
        request = Request(self.endpoint, data=payload,
                          headers={"Content-Type": "application/json"})
        with urlopen(request, timeout=5) as response:
            result = json.loads(response.read(1024 * 1024))
        if "error" in result:
            raise RuntimeError(result["error"].get("message", "erro RPC"))
        return result.get("result")


def load_paused(path: Path) -> set[str]:
    try:
        value = json.loads(path.read_text())
        return {gid for gid in value if isinstance(gid, str)} if isinstance(value, list) else set()
    except (OSError, json.JSONDecodeError):
        return set()


def save_paused(path: Path, paused: set[str]) -> None:
    temporary = path.with_suffix(path.suffix + ".tmp")
    temporary.write_text(json.dumps(sorted(paused)) + "\n")
    os.replace(temporary, path)


def run(endpoint: str, secret: str, threshold: int, interval: int, state: Path) -> None:
    rpc = AriaRpc(endpoint, secret)
    paused = load_paused(state)
    while True:
        try:
            level = battery_percent()
            allowed = level is None or level >= threshold
            if allowed:
                for gid in list(paused):
                    try:
                        rpc.call("aria2.unpause", [gid])
                    except RuntimeError as exc:
                        if "not found" not in str(exc).lower():
                            raise
                    paused.discard(gid)
                    save_paused(state, paused)
            else:
                active = rpc.call("aria2.tellActive", [["gid", "seeder"]]) or []
                for item in active:
                    gid = item.get("gid")
                    if item.get("seeder") == "true" and isinstance(gid, str):
                        rpc.call("aria2.forcePause", [gid])
                        paused.add(gid)
                        save_paused(state, paused)
        except Exception:
            # A transient RPC or sysfs failure must not terminate the monitor.
            pass
        time.sleep(interval)


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--rpc", required=True)
    parser.add_argument("--secret", required=True)
    parser.add_argument("--threshold", type=int, default=30)
    parser.add_argument("--interval", type=int, default=15)
    parser.add_argument("--state", required=True, type=Path)
    args = parser.parse_args()
    if not 1 <= args.threshold <= 100 or not 5 <= args.interval <= 300:
        parser.error("limite ou intervalo inválido")
    run(args.rpc, args.secret, args.threshold, args.interval, args.state)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
