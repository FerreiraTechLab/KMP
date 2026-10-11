#!/usr/bin/env python3
"""Stage, apply, and recover signed KMP Client package updates."""

from __future__ import annotations

import hashlib
import json
import os
from pathlib import Path, PurePosixPath
import shutil
import stat
import sys
import tempfile
import zipfile


STATE_DIR = Path(".kmp/client-update")
PENDING = "pending.json"
JOURNAL = "journal.json"
EXTERNAL_UPDATER = Path(".kmp/client-updater.py")
PRESERVED = ("conf", "diagnostics", "peer.txt", "catalog-url.txt")
MAX_FILES = 20_000
MAX_UNPACKED = 512 * 1024 * 1024
MAX_COMPRESSION_RATIO = 1000


def fsync_directory(path: Path) -> None:
    descriptor = os.open(path, os.O_RDONLY | getattr(os, "O_DIRECTORY", 0))
    try:
        os.fsync(descriptor)
    finally:
        os.close(descriptor)


def fsync_tree(path: Path) -> None:
    for root, directories, files in os.walk(path):
        root_path = Path(root)
        for filename in files:
            file_path = root_path / filename
            if file_path.is_symlink():
                continue
            with file_path.open("rb") as handle:
                os.fsync(handle.fileno())
        for directory in directories:
            directory_path = root_path / directory
            if not directory_path.is_symlink():
                fsync_directory(directory_path)
        fsync_directory(root_path)


def durable_json(path: Path, value: dict) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    temporary = path.with_suffix(path.suffix + ".tmp")
    with temporary.open("w", encoding="utf-8") as handle:
        json.dump(value, handle, ensure_ascii=False, sort_keys=True)
        handle.write("\n")
        handle.flush()
        os.fsync(handle.fileno())
    os.replace(temporary, path)
    fsync_directory(path.parent)


def remove_path(path: Path) -> None:
    if path.is_symlink() or path.is_file():
        path.unlink()
    elif path.is_dir():
        shutil.rmtree(path)


def safe_relative(name: str) -> bool:
    if not name or name.startswith("/") or "\\" in name or "\x00" in name or ":" in name:
        return False
    return all(part not in {"", ".", ".."} for part in name.rstrip("/").split("/"))


def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def validate_item(item: dict) -> None:
    if item.get("id") != "kmp-client" or item.get("install", {}).get("portId") != "kmp-client":
        raise ValueError("pacote não é uma atualização do KMP Client")
    if item.get("install", {}).get("paths") != ["KMP.sh", "KMP/"]:
        raise ValueError("raízes da atualização do Client são inválidas")
    if not isinstance(item.get("version"), str) or not item["version"]:
        raise ValueError("versão da atualização é inválida")
    digest = item.get("packageSha256")
    if not isinstance(digest, str) or len(digest) != 64 or any(c not in "0123456789abcdef" for c in digest):
        raise ValueError("SHA-256 da atualização é inválido")


def validate_archive(archive: zipfile.ZipFile, item: dict) -> list[tuple[zipfile.ZipInfo, int]]:
    entries = []
    names = set()
    total = 0
    for info in archive.infolist():
        name = info.filename.rstrip("/")
        if not safe_relative(info.filename) or not (name == "KMP.sh" or name == "KMP" or
                                                     name.startswith("KMP/")):
            raise ValueError("caminho inválido na atualização: " + info.filename)
        if name in names:
            raise ValueError("caminho duplicado na atualização: " + name)
        names.add(name)
        mode = info.external_attr >> 16
        file_type = stat.S_IFMT(mode)
        if file_type not in (0, stat.S_IFREG, stat.S_IFDIR) or file_type == stat.S_IFLNK:
            raise ValueError("link ou arquivo especial na atualização")
        if mode & (stat.S_ISUID | stat.S_ISGID):
            raise ValueError("permissão privilegiada na atualização")
        if info.flag_bits & 0x1:
            raise ValueError("arquivo criptografado na atualização")
        if info.file_size and info.compress_size == 0:
            raise ValueError("taxa de compressão inválida na atualização")
        if info.compress_size and info.file_size / info.compress_size > MAX_COMPRESSION_RATIO:
            raise ValueError("taxa de compressão excessiva na atualização")
        total += info.file_size
        if len(names) > MAX_FILES or total > MAX_UNPACKED:
            raise ValueError("atualização excede os limites de extração")
        permissions = 0o755 if mode & 0o111 or name.endswith(".sh") else 0o644
        entries.append((info, permissions))
    required = {"KMP.sh", "KMP/version.txt", "KMP/game.love", "KMP/self_update.py"}
    if not required.issubset(names):
        raise ValueError("atualização não contém todos os arquivos obrigatórios")
    version = archive.read("KMP/version.txt").decode("utf-8", "strict").strip()
    if version != item["version"]:
        raise ValueError("versão interna do pacote não confere")
    return entries


def copy_external_updater(base: Path, source: Path) -> None:
    destination = base / EXTERNAL_UPDATER
    destination.parent.mkdir(parents=True, exist_ok=True)
    temporary = destination.with_suffix(".tmp")
    shutil.copy2(source, temporary)
    os.chmod(temporary, 0o755)
    with temporary.open("rb") as handle:
        os.fsync(handle.fileno())
    os.replace(temporary, destination)
    fsync_directory(destination.parent)


def prepare(package: Path, base: Path, item: dict, updater_source: Path | None = None) -> Path:
    base = base.resolve()
    package = package.resolve()
    validate_item(item)
    if package.is_symlink() or not package.is_file() or package.name != item.get("packageFile"):
        raise ValueError("arquivo de atualização ausente ou inesperado")
    if sha256_file(package) != item["packageSha256"]:
        raise ValueError("SHA-256 da atualização não confere")
    state = base / STATE_DIR
    if state.is_symlink():
        raise ValueError("diretório de atualização inválido")
    state.mkdir(parents=True, exist_ok=True)
    recover(base)
    if (state / PENDING).exists():
        raise ValueError("já existe uma atualização pendente")
    stage = Path(tempfile.mkdtemp(prefix="stage-", dir=state))
    try:
        with zipfile.ZipFile(package) as archive:
            entries = validate_archive(archive, item)
            if archive.testzip() is not None:
                raise ValueError("CRC inválido na atualização")
            archive.extractall(stage)
            for info, mode in entries:
                target = stage / info.filename.rstrip("/")
                if target.is_file():
                    os.chmod(target, mode)
        fsync_tree(stage)
        updater = updater_source or Path(__file__).resolve()
        copy_external_updater(base, updater)
        pending = {"schemaVersion": 1, "version": item["version"], "stage": stage.name,
                   "packageSha256": item["packageSha256"]}
        durable_json(state / PENDING, pending)
        return state / PENDING
    except Exception:
        remove_path(stage)
        raise


def valid_state_record(value: dict, name: str) -> tuple[str, str]:
    if not isinstance(value, dict) or value.get("schemaVersion") != 1:
        raise ValueError(name + " inválido")
    version, stage = value.get("version"), value.get("stage")
    if not isinstance(version, str) or not version or not isinstance(stage, str) or \
       not stage.startswith("stage-") or "/" in stage:
        raise ValueError(name + " inválido")
    return version, stage


def restore_backup(base: Path, state: Path, journal: dict) -> None:
    backup = state / journal["backup"]
    if (backup / "KMP").exists():
        remove_path(base / "KMP")
        os.replace(backup / "KMP", base / "KMP")
    backup_script = backup / "KMP.sh"
    if backup_script.exists():
        os.replace(backup_script, base / "KMP.sh")
    fsync_directory(base)


def recover(base: Path) -> str:
    base = base.resolve()
    state = base / STATE_DIR
    journal_path = state / JOURNAL
    if not journal_path.exists():
        return "none"
    journal = json.loads(journal_path.read_text(encoding="utf-8"))
    version, stage_name = valid_state_record(journal, "journal de atualização")
    backup_name = journal.get("backup")
    if not isinstance(backup_name, str) or not backup_name.startswith("backup-") or "/" in backup_name:
        raise ValueError("journal de atualização inválido")
    installed_version = ""
    try:
        installed_version = (base / "KMP/version.txt").read_text().strip()
    except OSError:
        pass
    committed = journal.get("state") == "committed" and installed_version == version
    if not committed:
        restore_backup(base, state, journal)
    for path in (state / stage_name, state / backup_name):
        remove_path(path)
    journal_path.unlink()
    pending = state / PENDING
    if pending.exists():
        pending.unlink()
    fsync_directory(state)
    return "committed" if committed else "rolled_back"


def apply(base: Path, checkpoint=None) -> str:
    base = base.resolve()
    state = base / STATE_DIR
    pending_path = state / PENDING
    pending = json.loads(pending_path.read_text(encoding="utf-8"))
    version, stage_name = valid_state_record(pending, "atualização pendente")
    stage = state / stage_name
    if not (stage / "KMP").is_dir() or not (stage / "KMP.sh").is_file():
        raise ValueError("staging da atualização está incompleto")
    backup = Path(tempfile.mkdtemp(prefix="backup-", dir=state))
    shutil.copy2(base / "KMP.sh", backup / "KMP.sh")
    with (backup / "KMP.sh").open("rb") as handle:
        os.fsync(handle.fileno())
    journal = {**pending, "backup": backup.name, "state": "prepared"}
    durable_json(state / JOURNAL, journal)
    if checkpoint: checkpoint("prepared")
    try:
        os.replace(base / "KMP", backup / "KMP")
        fsync_directory(base)
        journal["state"] = "backed_up"
        durable_json(state / JOURNAL, journal)
        if checkpoint: checkpoint("backed_up")
        os.replace(stage / "KMP", base / "KMP")
        for relative in PRESERVED:
            source = backup / "KMP" / relative
            target = base / "KMP" / relative
            if source.exists() or source.is_symlink():
                if target.exists() or target.is_symlink():
                    remove_path(target)
                target.parent.mkdir(parents=True, exist_ok=True)
                if source.is_dir() and not source.is_symlink():
                    shutil.copytree(source, target, symlinks=True)
                else:
                    shutil.copy2(source, target, follow_symlinks=False)
        fsync_tree(base / "KMP")
        journal["state"] = "replaced"
        durable_json(state / JOURNAL, journal)
        if checkpoint: checkpoint("replaced")
        os.replace(stage / "KMP.sh", base / "KMP.sh")
        os.chmod(base / "KMP.sh", 0o755)
        fsync_directory(base)
        journal["state"] = "committed"
        durable_json(state / JOURNAL, journal)
        if checkpoint: checkpoint("committed")
        remove_path(stage)
        remove_path(backup)
        pending_path.unlink()
        (state / JOURNAL).unlink()
        fsync_directory(state)
        return version
    except Exception:
        if (state / JOURNAL).exists():
            recover(base)
        raise


def main() -> int:
    if len(sys.argv) == 3 and sys.argv[1] == "recover":
        print(recover(Path(sys.argv[2])))
        return 0
    if len(sys.argv) == 3 and sys.argv[1] == "apply":
        print(apply(Path(sys.argv[2])))
        return 0
    if len(sys.argv) == 6 and sys.argv[1] == "prepare":
        item = json.loads(Path(sys.argv[4]).read_text(encoding="utf-8"))
        print(prepare(Path(sys.argv[2]), Path(sys.argv[3]), item, Path(sys.argv[5])))
        return 0
    print("uso: self_update.py {prepare PACOTE BASE ITEM UPDATER|apply BASE|recover BASE}", file=sys.stderr)
    return 2


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except (OSError, ValueError, KeyError, json.JSONDecodeError, zipfile.BadZipFile) as exc:
        print("erro: " + str(exc), file=sys.stderr)
        raise SystemExit(1)
