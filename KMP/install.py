#!/usr/bin/env python3
"""Install a validated KMP ZIP without trusting paths inside the archive."""

import hashlib
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


def merge_preserved(source, destination):
    """Restore preserved user files without replacing package-owned files."""
    if not source.exists():
        return
    destination.mkdir(parents=True, exist_ok=True)
    for child in list(source.iterdir()):
        target = destination / child.name
        if child.is_dir() and not child.is_symlink():
            merge_preserved(child, target)
            try:
                child.rmdir()
            except OSError:
                pass
        elif not target.exists() and not target.is_symlink():
            os.replace(child, target)
    try:
        source.rmdir()
    except OSError:
        pass


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


def validate_update_transaction(base, transaction):
    if not isinstance(transaction, dict) or transaction.get("schemaVersion") != 2:
        raise ValueError("journal de atualização inválido")
    port_id = transaction.get("portId")
    roots = transaction.get("roots")
    new_roots = transaction.get("newRoots")
    stage_name = transaction.get("stage")
    backup_name = transaction.get("backup")
    old_record = transaction.get("oldRecord")
    record = transaction.get("record")
    if not isinstance(port_id, str) or not port_id or not all(
            c.islower() or c.isdigit() or c in "_-" for c in port_id):
        raise ValueError("journal de atualização inválido")
    if not isinstance(roots, list) or not roots or any(
            not safe_relative(root) or "/" in root for root in roots):
        raise ValueError("journal de atualização inválido")
    if not isinstance(new_roots, list) or any(root not in roots for root in new_roots):
        raise ValueError("journal de atualização inválido")
    if not isinstance(stage_name, str) or not stage_name.startswith(".kmp-stage-") or "/" in stage_name:
        raise ValueError("journal de atualização inválido")
    if not isinstance(backup_name, str) or not backup_name.startswith(".kmp-backup-") or "/" in backup_name:
        raise ValueError("journal de atualização inválido")
    if not isinstance(old_record, dict) or old_record.get("portId") != port_id:
        raise ValueError("journal de atualização inválido")
    if not isinstance(record, dict) or record.get("portId") != port_id:
        raise ValueError("journal de atualização inválido")
    return (port_id, roots, new_roots, base / stage_name, base / backup_name,
            old_record, record)


def recover_transaction(base, journal):
    transaction = json.loads(journal.read_text(encoding="utf-8"))
    if transaction.get("schemaVersion") == 2:
        port_id, roots, new_roots, stage, backup, old_record, record = \
            validate_update_transaction(base, transaction)
        manifest = base / ".kmp" / "manifests" / (port_id + ".json")
        try:
            current_record = json.loads(manifest.read_text(encoding="utf-8"))
        except (OSError, json.JSONDecodeError) as exc:
            raise ValueError("manifesto de atualização inválido") from exc
        committed = current_record == record and all((base / root).exists() for root in new_roots)
        if not committed and current_record != old_record:
            raise ValueError("manifesto diverge de atualização interrompida")
        if not committed:
            old_roots = set(old_record.get("roots", []))
            for root in roots:
                saved = backup / root
                target = base / root
                if saved.exists() or saved.is_symlink():
                    remove_path(target)
                    os.replace(saved, target)
                elif root not in old_roots and root in new_roots and not (stage / root).exists():
                    remove_path(target)
            fsync_directory(base)
        remove_path(stage)
        remove_path(backup)
        journal.unlink()
        fsync_directory(journal.parent)
        return "committed" if committed else "rolled_back"
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


def copy_user_files(backup, destination, package_files):
    """Copy files not owned by the old package into the replacement tree."""
    owned = set(package_files)
    for source in sorted(backup.rglob("*")):
        relative = source.relative_to(backup).as_posix()
        if source.is_symlink():
            raise ValueError("save contém link simbólico: " + relative)
        if source.is_dir():
            continue
        if relative in owned:
            continue
        target = destination / relative
        if not target.exists() and not target.is_symlink():
            target.parent.mkdir(parents=True, exist_ok=True)
            shutil.copy2(source, target)


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
    expected_digest = item.get("packageSha256")
    if expected_digest is not None:
        if not isinstance(expected_digest, str) or len(expected_digest) != 64 or any(
                char not in "0123456789abcdef" for char in expected_digest):
            raise ValueError("SHA-256 do pacote inválido")
        digest = hashlib.sha256()
        with zip_path.open("rb") as package_handle:
            for chunk in iter(lambda: package_handle.read(1024 * 1024), b""):
                digest.update(chunk)
        if digest.hexdigest() != expected_digest:
            raise ValueError("SHA-256 do pacote não confere")
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
        directory_roots = {path.rstrip("/").split("/")[0]
                           for path in item["install"]["paths"] if path.endswith("/")}
        preserved_dir = kmp_dir / "preserved" / port_id
        if preserved_dir.is_symlink():
            raise ValueError("diretório de saves preservados inválido")
        for root in roots:
            target = base / root
            if target.exists():
                if root not in directory_roots or not target.is_dir() or target.is_symlink():
                    raise ValueError("destino já ocupado: " + root)
                preserved_target = preserved_dir / root
                if preserved_target.exists() or preserved_target.is_symlink():
                    raise ValueError("já existem saves preservados para: " + root)
                preserved_target.parent.mkdir(parents=True, exist_ok=True)
                os.replace(target, preserved_target)
                fsync_directory(base)
        stage = Path(tempfile.mkdtemp(prefix=".kmp-stage-", dir=base))
        manifest_dir.mkdir(parents=True, exist_ok=True)
        transaction_dir.mkdir(parents=True, exist_ok=True)
        record = {
            "id": item["id"], "version": item["version"],
            "infoHash": item["infoHash"], "portId": port_id,
            "catalogSequence": item.get("catalogSequence", 0),
            "packageFile": item["packageFile"], "files": files, "roots": roots,
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
        for root in directory_roots:
            merge_preserved(preserved_dir / root, base / root)
        try:
            preserved_dir.rmdir()
        except OSError:
            pass
    return manifest


def update(zip_path, base_path, item, checkpoint=None):
    base = Path(base_path).resolve()
    if not base.is_dir():
        raise ValueError("diretório de ports não existe")
    if zip_path.is_symlink() or not zip_path.is_file() or zip_path.name != item["packageFile"]:
        raise ValueError("pacote baixado ausente ou com nome inesperado")
    expected_digest = item.get("packageSha256")
    if expected_digest is not None:
        if not isinstance(expected_digest, str) or len(expected_digest) != 64 or any(
                char not in "0123456789abcdef" for char in expected_digest):
            raise ValueError("SHA-256 do pacote inválido")
        digest = hashlib.sha256()
        with zip_path.open("rb") as package_handle:
            for chunk in iter(lambda: package_handle.read(1024 * 1024), b""):
                digest.update(chunk)
        if digest.hexdigest() != expected_digest:
            raise ValueError("SHA-256 do pacote não confere")
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
    old_record = json.loads(manifest.read_text(encoding="utf-8"))
    if old_record.get("portId") != port_id or old_record.get("id") != item.get("id"):
        raise ValueError("pacote não corresponde ao port instalado")
    old_files = old_record.get("files")
    old_roots = old_record.get("roots")
    if not isinstance(old_files, list) or not isinstance(old_roots, list) or any(
            not safe_relative(name) for name in old_files + old_roots):
        raise ValueError("manifesto instalado inválido")
    with zipfile.ZipFile(zip_path) as archive:
        files, unpacked_bytes, modes = validate_zip(archive, item)
        bad_member = archive.testzip()
        if bad_member:
            raise ValueError("CRC inválido no ZIP: " + bad_member)
        if shutil.disk_usage(base).free < unpacked_bytes + 64 * 1024 * 1024:
            raise ValueError("espaço insuficiente para atualizar o ZIP")
        new_roots = sorted({path.split("/")[0] for path in item["install"]["paths"]})
        roots = sorted(set(old_roots) | set(new_roots))
        if any("/" in root for root in roots):
            raise ValueError("raiz inválida no manifesto")
        stage = Path(tempfile.mkdtemp(prefix=".kmp-stage-", dir=base))
        backup = Path(tempfile.mkdtemp(prefix=".kmp-backup-", dir=base))
        transaction_dir.mkdir(parents=True, exist_ok=True)
        record = {
            "id": item["id"], "version": item["version"],
            "infoHash": item["infoHash"], "portId": port_id,
            "catalogSequence": item.get("catalogSequence", 0),
            "packageFile": item["packageFile"], "files": files, "roots": new_roots,
        }
        journal = transaction_dir / (port_id + ".json")
        transaction = {
            "schemaVersion": 2, "state": "preparing", "portId": port_id,
            "stage": stage.name, "backup": backup.name, "roots": roots,
            "newRoots": new_roots, "oldRecord": old_record, "record": record,
        }
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
            for root in roots:
                target = base / root
                if target.exists() or target.is_symlink():
                    os.replace(target, backup / root)
                    fsync_directory(base)
                    fsync_directory(backup)
                if checkpoint: checkpoint("backed_up:" + root)
            transaction["state"] = "replacing"
            durable_json(journal, transaction)
            for root in new_roots:
                os.replace(stage / root, base / root)
                fsync_directory(base)
                if checkpoint: checkpoint("replaced:" + root)
            copy_user_files(backup, base, old_files)
            for root in new_roots:
                installed_root = base / root
                if installed_root.is_dir():
                    fsync_tree(installed_root)
                else:
                    with installed_root.open("rb") as handle:
                        os.fsync(handle.fileno())
            if checkpoint: checkpoint("merged")
            durable_json(manifest, record)
            if checkpoint: checkpoint("manifest")
            transaction["state"] = "committed"
            durable_json(journal, transaction)
            remove_path(stage)
            remove_path(backup)
            journal.unlink()
            fsync_directory(transaction_dir)
        except Exception:
            if journal.exists():
                outcome = recover_transaction(base, journal)
                if outcome == "committed":
                    return manifest
            else:
                remove_path(stage)
                remove_path(backup)
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
    item_id = record.get("id")
    if not isinstance(files, list) or not isinstance(roots, list) or any(
        not safe_relative(name) for name in files + roots
    ):
        raise ValueError("manifesto contém caminhos inválidos")
    if not isinstance(item_id, str) or not item_id or not all(
            c.islower() or c.isdigit() or c in "_-" for c in item_id):
        raise ValueError("identificador do item inválido no manifesto")
    # Complete removal is intentional: package files, saves, settings and any
    # user-created content below a declared port root are all deleted.
    for root in roots:
        if "/" in root:
            raise ValueError("raiz inválida no manifesto")
        path = base / root
        if path.exists() or path.is_symlink():
            remove_path(path)
    preserved_dir = base / ".kmp" / "preserved" / port_id
    if preserved_dir.exists() or preserved_dir.is_symlink():
        remove_path(preserved_dir)
    torrent_dir = base / ".kmp" / "torrents" / item_id
    if torrent_dir.exists() or torrent_dir.is_symlink():
        remove_path(torrent_dir)
    p2p_root = base / ".kmp" / "p2p-tests"
    if p2p_root.is_symlink():
        raise ValueError("diretório de testes P2P inválido")
    if p2p_root.is_dir():
        for test_dir in p2p_root.glob(item_id + "-*"):
            remove_path(test_dir)
    updates_root = base / ".kmp" / "updates"
    if updates_root.is_symlink():
        raise ValueError("diretório de atualizações inválido")
    if updates_root.is_dir():
        for update_dir in updates_root.glob(item_id + "-*"):
            remove_path(update_dir)
    manifest.unlink()
    fsync_directory(base)


def main():
    if len(sys.argv) == 5 and sys.argv[1] == "install":
        item = json.loads(Path(sys.argv[4]).read_text(encoding="utf-8"))
        print(install(Path(sys.argv[2]), Path(sys.argv[3]), item))
    elif len(sys.argv) == 5 and sys.argv[1] == "update":
        item = json.loads(Path(sys.argv[4]).read_text(encoding="utf-8"))
        print(update(Path(sys.argv[2]), Path(sys.argv[3]), item))
    elif len(sys.argv) == 4 and sys.argv[1] == "uninstall":
        uninstall(Path(sys.argv[2]), sys.argv[3])
        print("Removido")
    elif len(sys.argv) == 3 and sys.argv[1] == "recover":
        print(json.dumps(recover(Path(sys.argv[2]))))
    else:
        raise ValueError("uso: install.py {install|update} ZIP PORTS ITEM.json | uninstall PORTS ID | recover BASE")


if __name__ == "__main__":
    try:
        main()
    except (OSError, ValueError, zipfile.BadZipFile, KeyError) as exc:
        print("Erro de instalação: " + str(exc), file=sys.stderr)
        sys.exit(1)
