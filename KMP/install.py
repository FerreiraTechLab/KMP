#!/usr/bin/env python3
"""Install a validated KMP ZIP without trusting paths inside the archive."""

import json
import os
from pathlib import Path, PurePosixPath
import shutil
import sys
import tempfile
import zipfile


def fsync_directory(path):
    descriptor = os.open(path, os.O_RDONLY | getattr(os, "O_DIRECTORY", 0))
    try:
        os.fsync(descriptor)
    finally:
        os.close(descriptor)


def durable_json(path, value):
    path.parent.mkdir(parents=True, exist_ok=True)
    temporary = path.with_suffix(path.suffix + ".tmp")
    with temporary.open("w", encoding="utf-8") as handle:
        json.dump(value, handle, ensure_ascii=False, sort_keys=True)
        handle.write("\n")
        handle.flush()
        os.fsync(handle.fileno())
    os.replace(temporary, path)
    fsync_directory(path.parent)


def fsync_tree(root):
    directories = [root]
    for path in root.rglob("*"):
        if path.is_dir():
            directories.append(path)
        elif path.is_file():
            with path.open("rb") as handle:
                os.fsync(handle.fileno())
    for directory in sorted(directories, key=lambda p: len(p.parts), reverse=True):
        fsync_directory(directory)


def remove_path(path):
    if path.is_symlink() or path.is_file():
        path.unlink()
    elif path.is_dir():
        shutil.rmtree(path)


def validate_transaction(base, transaction):
    if not isinstance(transaction, dict) or transaction.get("schemaVersion") != 1:
        raise ValueError("journal de instalação inválido")
    port_id = transaction.get("portId")
    roots = transaction.get("roots")
    stage_name = transaction.get("stage")
    record = transaction.get("record")
    if not isinstance(port_id, str) or not port_id or not all(
            c.islower() or c.isdigit() or c in "_-" for c in port_id):
        raise ValueError("journal de instalação inválido")
    if not isinstance(roots, list) or not roots or any(
            not safe_relative(root) or "/" in root for root in roots):
        raise ValueError("journal de instalação inválido")
    if not isinstance(stage_name, str) or not stage_name.startswith(".kmp-stage-") or "/" in stage_name:
        raise ValueError("journal de instalação inválido")
    if not isinstance(record, dict) or record.get("portId") != port_id or record.get("roots") != roots:
        raise ValueError("journal de instalação inválido")
    return port_id, roots, base / stage_name, record


def recover_transaction(base, journal):
    transaction = json.loads(journal.read_text(encoding="utf-8"))
    port_id, roots, stage, record = validate_transaction(base, transaction)
    manifest_dir = base / ".kmp" / "manifests"
    manifest = manifest_dir / (port_id + ".json")
    committed = False
    if manifest.is_file():
        try:
            committed = json.loads(manifest.read_text(encoding="utf-8")) == record and all(
                (base / root).exists() for root in roots)
        except (OSError, json.JSONDecodeError):
            committed = False
        if not committed:
            raise ValueError("manifesto diverge de instalação interrompida")
    if not committed:
        for root in roots:
            remove_path(base / root)
        temporary_manifest = manifest.with_suffix(".json.tmp")
        if temporary_manifest.exists() or temporary_manifest.is_symlink():
            remove_path(temporary_manifest)
        fsync_directory(base)
    remove_path(stage)
    journal.unlink()
    fsync_directory(journal.parent)
    return "committed" if committed else "rolled_back"


def recover(base_path):
    base = Path(base_path).resolve()
    transaction_dir = base / ".kmp" / "transactions"
    if not transaction_dir.exists():
        return []
    if transaction_dir.is_symlink():
        raise ValueError("diretório de transações inválido")
    results = []
    for journal in sorted(transaction_dir.glob("*.json")):
        results.append((journal.stem, recover_transaction(base, journal)))
    return results


def safe_relative(name):
    if not name or "\\" in name or "\x00" in name or ":" in name:
        return False
    path = PurePosixPath(name)
    return not path.is_absolute() and all(part not in (".", "..") for part in name.split("/") if part)


def checked_path(base, name):
    if not safe_relative(name):
        raise ValueError("caminho inválido no manifesto")
    path = base
    for part in PurePosixPath(name).parts:
        path = path / part
        if path.is_symlink():
            raise ValueError("caminho substituído por link: " + name)
    return path


def validate_zip(archive, item):
    expected = item["install"]["paths"]
    if not expected or any(not safe_relative(path) for path in expected):
        raise ValueError("caminhos esperados inválidos")
    names = []
    files = []
    modes = {}
    total = 0
    for info in archive.infolist():
        name = info.filename.rstrip("/")
        if not safe_relative(name):
            raise ValueError("caminho inválido no ZIP: " + info.filename)
        mode = (info.external_attr >> 16) & 0o170000
        if mode not in (0, 0o100000, 0o040000):
            raise ValueError("link ou arquivo especial no ZIP")
        if not any(name == path.rstrip("/") or
                   (path.endswith("/") and name.startswith(path)) for path in expected):
            raise ValueError("arquivo fora do pacote declarado: " + name)
        names.append(name)
        if not info.is_dir():
            files.append(name)
            permissions = (info.external_attr >> 16) & 0o777
            modes[name] = 0o755 if permissions & 0o111 or name.endswith(".sh") else 0o644
        total += info.file_size
        if len(names) > 10000 or total > max(item["sizeBytes"] * 16, 64 * 1024 * 1024):
            raise ValueError("ZIP excede o limite de extração")
    if len(names) != len(set(names)):
        raise ValueError("nomes duplicados no ZIP")
    for path in expected:
        target = path.rstrip("/")
        if not any(name == target or (path.endswith("/") and name.startswith(path)) for name in names):
            raise ValueError("arquivo esperado ausente: " + path)
    return files, total, modes


def install(zip_path, base_path, item, checkpoint=None):
    base = Path(base_path).resolve()
    if not base.is_dir():
        raise ValueError("diretório de ports não existe")
    if zip_path.is_symlink() or not zip_path.is_file() or zip_path.name != item["packageFile"]:
        raise ValueError("pacote baixado ausente ou com nome inesperado")
    port_id = item["install"]["portId"]
    if not port_id or not all(c.islower() or c.isdigit() or c in "_-" for c in port_id):
        raise ValueError("identificador do port inválido")
    kmp_dir = base / ".kmp"
    manifest_dir = kmp_dir / "manifests"
    transaction_dir = kmp_dir / "transactions"
    if kmp_dir.is_symlink() or manifest_dir.is_symlink() or transaction_dir.is_symlink():
        raise ValueError("diretório de manifestos inválido")
    recover(base)
    manifest = manifest_dir / (port_id + ".json")
    if manifest.exists():
        raise ValueError("port já instalado")
    with zipfile.ZipFile(zip_path) as archive:
        files, unpacked_bytes, modes = validate_zip(archive, item)
        bad_member = archive.testzip()
        if bad_member:
            raise ValueError("CRC inválido no ZIP: " + bad_member)
        if shutil.disk_usage(base).free < unpacked_bytes + 64 * 1024 * 1024:
            raise ValueError("espaço insuficiente para extrair o ZIP")
        roots = sorted({path.split("/")[0] for path in item["install"]["paths"]})
        for root in roots:
            if (base / root).exists():
                raise ValueError("destino já ocupado: " + root)
        stage = Path(tempfile.mkdtemp(prefix=".kmp-stage-", dir=base))
        manifest_dir.mkdir(parents=True, exist_ok=True)
        transaction_dir.mkdir(parents=True, exist_ok=True)
        record = {
            "id": item["id"], "version": item["version"],
            "infoHash": item["infoHash"], "portId": port_id,
            "files": files, "roots": roots,
        }
        journal = transaction_dir / (port_id + ".json")
        transaction = {"schemaVersion": 1, "state": "preparing", "portId": port_id,
                       "stage": stage.name, "roots": roots, "moved": [], "record": record}
        try:
            durable_json(journal, transaction)
            if checkpoint: checkpoint("journaled")
            archive.extractall(stage)
            for name, mode in modes.items():
                os.chmod(stage / name, mode)
            fsync_tree(stage)
            transaction["state"] = "prepared"
            durable_json(journal, transaction)
            if checkpoint: checkpoint("prepared")
            transaction["state"] = "moving"
            for root in roots:
                os.replace(stage / root, base / root)
                fsync_directory(base)
                if checkpoint: checkpoint("replaced:" + root)
                transaction["moved"].append(root)
                durable_json(journal, transaction)
                if checkpoint: checkpoint("moved:" + root)
            durable_json(manifest, record)
            if checkpoint: checkpoint("manifest")
            transaction["state"] = "committed"
            durable_json(journal, transaction)
            remove_path(stage)
            journal.unlink()
            fsync_directory(transaction_dir)
        except Exception:
            if journal.exists():
                recover_transaction(base, journal)
            else:
                remove_path(stage)
            raise
    return manifest


def uninstall(base_path, port_id):
    base = Path(base_path).resolve()
    recover(base)
    if not port_id or not all(c.islower() or c.isdigit() or c in "_-" for c in port_id):
        raise ValueError("identificador do port inválido")
    manifest = base / ".kmp" / "manifests" / (port_id + ".json")
    record = json.loads(manifest.read_text(encoding="utf-8"))
    if record.get("portId") != port_id:
        raise ValueError("manifesto não corresponde ao port")
    files = record.get("files", [])
    roots = record.get("roots", [])
    if not isinstance(files, list) or not isinstance(roots, list) or any(
        not safe_relative(name) for name in files + roots
    ):
        raise ValueError("manifesto contém caminhos inválidos")
    for name in files:
        path = checked_path(base, name)
        if path.is_file():
            path.unlink()
    directories = set(roots)
    for name in files:
        parent = PurePosixPath(name).parent
        while str(parent) != ".":
            directories.add(str(parent))
            parent = parent.parent
    for name in sorted(directories, key=lambda entry: entry.count("/"), reverse=True):
        path = checked_path(base, name)
        if path.is_dir():
            try:
                path.rmdir()
            except OSError:
                pass  # Conteúdo adicionado pelo usuário permanece no lugar.
    manifest.unlink()


def main():
    if len(sys.argv) == 5 and sys.argv[1] == "install":
        item = json.loads(Path(sys.argv[4]).read_text(encoding="utf-8"))
        print(install(Path(sys.argv[2]), Path(sys.argv[3]), item))
    elif len(sys.argv) == 4 and sys.argv[1] == "uninstall":
        uninstall(Path(sys.argv[2]), sys.argv[3])
        print("Removido")
    elif len(sys.argv) == 3 and sys.argv[1] == "recover":
        print(json.dumps(recover(Path(sys.argv[2]))))
    else:
        raise ValueError("uso: install.py install ZIP PORTS ITEM.json | uninstall PORTS ID | recover BASE")


if __name__ == "__main__":
    try:
        main()
    except (OSError, ValueError, zipfile.BadZipFile, KeyError) as exc:
        print("Erro de instalação: " + str(exc), file=sys.stderr)
        sys.exit(1)
