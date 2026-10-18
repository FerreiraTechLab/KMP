#!/usr/bin/env python3
"""Create a bounded, redacted KMP support bundle."""

from __future__ import annotations

import argparse
from datetime import datetime, timezone
import json
import os
from pathlib import Path
import platform
import re
import shutil
import sys
from urllib.parse import urlsplit
from urllib.request import Request, urlopen
import zipfile


MAX_LOG_BYTES = 512 * 1024
LOG_FILES = (
    ("kmp.log", "log.txt"),
    ("aria2.log", "conf/daemon/aria2.log"),
    ("aria2-old.log", "conf/daemon/aria2.log.old"),
    ("battery-monitor.log", "conf/daemon/battery-monitor.log"),
    ("network-metrics.jsonl", "conf/network-metrics.jsonl"),
)
SECRET_FILES = ("conf/daemon/rpc.secret", "conf/daemon/rpc.env")
REDACTIONS = (
    re.compile(r"(?i)(rpc-secret(?:=|:|\s)+)([^\s&]+)"),
    re.compile(r"(?i)(KMP_ARIA2_SECRET=)([^\s]+)"),
    re.compile(r"(?i)(authorization:\s*(?:bearer|basic)\s+)([^\s]+)"),
    re.compile(r"(?i)((?:token|access_token|api_key|signature|password)=)([^&\s]+)"),
    re.compile(r"\b(?:ghp|github_pat)_[A-Za-z0-9_]{20,}\b"),
)


def read_tail(path: Path, limit: int = MAX_LOG_BYTES) -> tuple[bytes, bool]:
    size = path.stat().st_size
    with path.open("rb") as handle:
        if size > limit:
            handle.seek(-limit, os.SEEK_END)
        return handle.read(limit), size > limit


def secret_values(game_dir: Path) -> set[str]:
    values: set[str] = set()
    for relative in SECRET_FILES:
        path = game_dir / relative
        if path.is_file() and not path.is_symlink():
            for line in path.read_text(encoding="utf-8", errors="replace").splitlines():
                value = line.split("=", 1)[-1].strip()
                if len(value) >= 8:
                    values.add(value)
    return values


def redact(text: str, secrets: set[str]) -> str:
    for secret in sorted(secrets, key=len, reverse=True):
        text = text.replace(secret, "[REDACTED]")
    for pattern in REDACTIONS:
        if pattern.groups >= 2:
            text = pattern.sub(lambda match: match.group(1) + "[REDACTED]", text)
        else:
            text = pattern.sub("[REDACTED]", text)
    return text


def read_json(path: Path) -> dict:
    try:
        value = json.loads(path.read_text(encoding="utf-8"))
        return value if isinstance(value, dict) else {}
    except (OSError, ValueError):
        return {}


def os_release() -> dict[str, str]:
    result = {}
    try:
        lines = Path("/etc/os-release").read_text(encoding="utf-8").splitlines()
    except OSError:
        return result
    for line in lines:
        if "=" in line:
            key, value = line.split("=", 1)
            if key in {"ID", "VERSION_ID", "PRETTY_NAME"}:
                result[key] = value.strip().strip('"')
    return result


def battery_status(root: Path = Path("/sys/class/power_supply")) -> list[dict]:
    batteries = []
    if not root.is_dir():
        return batteries
    for supply in sorted(root.iterdir()):
        try:
            if (supply / "type").read_text().strip().lower() != "battery":
                continue
            item = {"name": supply.name}
            for source, target in (("capacity", "percent"), ("status", "status")):
                path = supply / source
                if path.is_file():
                    value = path.read_text().strip()
                    item[target] = int(value) if source == "capacity" and value.isdigit() else value
            batteries.append(item)
        except OSError:
            continue
    return batteries


def daemon_status(config_dir: Path) -> dict:
    state_dir = config_dir / "daemon"
    result = {"running": False}
    try:
        pid_text = (state_dir / "pid").read_text().strip()
        if pid_text.isdigit():
            result["pid"] = int(pid_text)
            result["running"] = Path("/proc", pid_text).exists()
    except OSError:
        pass
    settings = {"listen_port": "6881", "upload_limit": "100K", "download_limit": "1M",
                "max_concurrent_downloads": "50", "seed_battery_min": "30",
                "community_node": "1", "community_storage_mb": "4096"}
    try:
        for line in (state_dir / "settings.conf").read_text().splitlines():
            if "=" in line:
                key, value = line.split("=", 1)
                if key in {"listen_port", "upload_limit", "download_limit", "max_concurrent_downloads",
                           "seed_battery_min", "community_node", "community_storage_mb"}:
                    settings[key] = value
    except OSError:
        pass
    result["settings"] = settings
    try:
        paused = json.loads((state_dir / "battery-paused.json").read_text())
        result["batteryPausedCount"] = len(paused) if isinstance(paused, list) else 0
    except (OSError, ValueError):
        result["batteryPausedCount"] = 0
    result["torrents"] = torrent_summary(state_dir)
    mapping = read_json(state_dir / "port-mapping.json")
    result["portMapping"] = mapping if mapping else {"active": False}
    return result


def rpc_credentials(state_dir: Path) -> tuple[str, str] | None:
    values = {}
    try:
        for line in (state_dir / "rpc.env").read_text().splitlines():
            if "=" in line:
                key, value = line.split("=", 1)
                values[key] = value.strip()
    except OSError:
        return None
    endpoint = values.get("KMP_ARIA2_RPC", "")
    secret = values.get("KMP_ARIA2_SECRET", "")
    parsed = urlsplit(endpoint)
    if parsed.scheme != "http" or parsed.hostname not in {"127.0.0.1", "localhost"} or not secret:
        return None
    return endpoint, secret


def rpc_call(endpoint: str, secret: str, method: str, parameters: list) -> object:
    payload = json.dumps({"jsonrpc": "2.0", "id": "kmp-diagnostic", "method": method,
                          "params": ["token:" + secret, *parameters]}).encode()
    request = Request(endpoint, data=payload, headers={"Content-Type": "application/json"})
    with urlopen(request, timeout=3) as response:
        document = json.loads(response.read())
    if not isinstance(document, dict) or "result" not in document:
        raise ValueError("resposta RPC inválida")
    return document["result"]


def summarize_torrents(groups: list[list[dict]]) -> dict:
    summary = {"total": 0, "active": 0, "waiting": 0, "stopped": 0,
               "seeding": 0, "paused": 0, "errors": 0}
    labels = ("active", "waiting", "stopped")
    for label, items in zip(labels, groups):
        summary[label] = len(items)
        summary["total"] += len(items)
        for item in items:
            status = item.get("status")
            if status == "paused":
                summary["paused"] += 1
            if status == "error":
                summary["errors"] += 1
            if status in {"active", "complete"} and item.get("totalLength") not in {None, "0"} and \
               item.get("completedLength") == item.get("totalLength"):
                summary["seeding"] += 1
    return summary


def torrent_summary(state_dir: Path) -> dict:
    credentials = rpc_credentials(state_dir)
    if not credentials:
        return {"available": False}
    endpoint, secret = credentials
    keys = ["status", "totalLength", "completedLength"]
    try:
        version = rpc_call(endpoint, secret, "aria2.getVersion", [])
        groups = [
            rpc_call(endpoint, secret, "aria2.tellActive", [keys]),
            rpc_call(endpoint, secret, "aria2.tellWaiting", [0, 1000, keys]),
            rpc_call(endpoint, secret, "aria2.tellStopped", [0, 1000, keys]),
        ]
        if not all(isinstance(items, list) for items in groups):
            raise ValueError("lista RPC inválida")
        backend = version.get("version") if isinstance(version, dict) else None
        features = version.get("enabledFeatures", []) if isinstance(version, dict) else []
        result = {"available": True, "backend": backend, "features": features,
                  **summarize_torrents(groups)}
        if isinstance(backend, str) and backend.startswith("kmp-torrentd "):
            try:
                network = rpc_call(endpoint, secret, "kmp.getNetworkStats", [])
                if isinstance(network, dict):
                    result["network"] = network
            except (OSError, ValueError, json.JSONDecodeError) as exc:
                result["networkError"] = type(exc).__name__
        return result
    except (OSError, ValueError, json.JSONDecodeError) as exc:
        return {"available": False, "error": type(exc).__name__}


def catalog_status(config_dir: Path) -> dict:
    state = read_json(config_dir / "catalog/state.json")
    active = read_json(config_dir / "catalog/active.json")
    return {
        "acceptedSequence": state.get("highestSequence", 0),
        "lastTrustedTime": state.get("lastTrustedTime"),
        "activeSchemaVersion": active.get("schemaVersion"),
        "activeSequence": active.get("sequence"),
        "activeItems": len(active.get("items", [])) if isinstance(active.get("items"), list) else 0,
    }


def installed_ports(ports_dir: Path) -> list[dict]:
    result = []
    manifests = ports_dir / ".kmp/manifests"
    if not manifests.is_dir():
        return result
    for path in sorted(manifests.glob("*.json"))[:1000]:
        if path.is_symlink():
            continue
        value = read_json(path)
        item = {key: value[key] for key in
                ("id", "portId", "version", "revision", "variantId", "catalogSequence")
                if key in value}
        item["manifestFormat"] = "current" if "revision" in value and "variantId" in value else "legacy"
        result.append(item)
    return result


def unique_output(output_dir: Path) -> Path:
    timestamp = datetime.now(timezone.utc).strftime("%Y%m%d-%H%M%S")
    candidate = output_dir / f"kmp-diagnostic-{timestamp}.zip"
    counter = 1
    while candidate.exists():
        candidate = output_dir / f"kmp-diagnostic-{timestamp}-{counter}.zip"
        counter += 1
    return candidate


def create_bundle(game_dir: Path, config_dir: Path, output_dir: Path,
                  app_version: str) -> tuple[Path, dict]:
    game_dir = game_dir.resolve()
    config_dir = config_dir.resolve()
    output_dir.mkdir(parents=True, exist_ok=True)
    output = unique_output(output_dir)
    disk = shutil.disk_usage(game_dir)
    metadata = {
        "formatVersion": 1,
        "createdAt": datetime.now(timezone.utc).isoformat(timespec="seconds").replace("+00:00", "Z"),
        "appVersion": app_version,
        "system": {"uname": list(platform.uname()), "osRelease": os_release(),
                   "python": platform.python_version(), "machine": platform.machine()},
        "storage": {"path": str(game_dir), "totalBytes": disk.total,
                    "freeBytes": disk.free},
        "battery": battery_status(),
        "daemon": daemon_status(config_dir),
        "catalog": catalog_status(config_dir),
        "installedPorts": installed_ports(game_dir.parent),
        "logs": [],
    }
    secrets = secret_values(game_dir)
    with zipfile.ZipFile(output, "x", zipfile.ZIP_DEFLATED) as archive:
        for archive_name, relative in LOG_FILES:
            source = game_dir / relative
            if not source.is_file() or source.is_symlink():
                continue
            raw, truncated = read_tail(source)
            clean = redact(raw.decode("utf-8", "replace"), secrets)
            archive.writestr(f"logs/{archive_name}", clean)
            metadata["logs"].append({"name": archive_name, "sourceBytes": source.stat().st_size,
                                     "includedBytes": len(clean.encode()), "truncated": truncated})
        archive.writestr("diagnostic.json", json.dumps(metadata, ensure_ascii=False,
                                                        indent=2, sort_keys=True) + "\n")
    os.chmod(output, 0o644)
    return output, metadata


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--game-dir", required=True, type=Path)
    parser.add_argument("--config-dir", required=True, type=Path)
    parser.add_argument("--output-dir", required=True, type=Path)
    parser.add_argument("--app-version", required=True)
    args = parser.parse_args()
    try:
        output, metadata = create_bundle(args.game_dir, args.config_dir, args.output_dir,
                                         args.app_version)
    except (OSError, ValueError, zipfile.BadZipFile) as exc:
        print(json.dumps({"ok": False, "error": str(exc)}, ensure_ascii=False))
        return 1
    print(json.dumps({"ok": True, "path": str(output),
                      "logs": len(metadata["logs"])}, ensure_ascii=False))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
