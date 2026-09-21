#!/usr/bin/env python3
"""Install a validated KMP ZIP without trusting paths inside the archive."""

import json
import os
from pathlib import Path, PurePosixPath
import shutil
import sys
import tempfile
import zipfile


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


def install(zip_path, base_path, item):
    base = Path(base_path).resolve()
    if not base.is_dir():
        raise ValueError("diretório de ports não existe")
    if zip_path.is_symlink() or not zip_path.is_file() or zip_path.name != item["packageFile"]:
        raise ValueError("pacote baixado ausente ou com nome inesperado")
    port_id = item["install"]["portId"]
    if not port_id or not all(c.islower() or c.isdigit() or c in "_-" for c in port_id):
        raise ValueError("identificador do port inválido")
    manifest_dir = base / ".kmp" / "manifests"
    if (base / ".kmp").is_symlink() or manifest_dir.is_symlink():
        raise ValueError("diretório de manifestos inválido")
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
        moved = []
        try:
            archive.extractall(stage)
            for name, mode in modes.items():
                os.chmod(stage / name, mode)
            for root in roots:
                os.replace(stage / root, base / root)
                moved.append(root)
            manifest_dir.mkdir(parents=True, exist_ok=True)
            record = {
                "id": item["id"], "version": item["version"],
                "infoHash": item["infoHash"], "portId": port_id,
                "files": files,
                "roots": roots,
            }
            temporary = manifest.with_suffix(".json.tmp")
            temporary.write_text(json.dumps(record, ensure_ascii=False), encoding="utf-8")
            os.replace(temporary, manifest)
        except Exception:
            for root in moved:
                target = base / root
                if target.is_dir():
                    shutil.rmtree(target)
                elif target.exists():
                    target.unlink()
            raise
        finally:
            shutil.rmtree(stage)
    return manifest


def uninstall(base_path, port_id):
    base = Path(base_path).resolve()
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
    else:
        raise ValueError("uso: install.py install ZIP PORTS ITEM.json | uninstall PORTS ID")


if __name__ == "__main__":
    try:
        main()
    except (OSError, ValueError, zipfile.BadZipFile, KeyError) as exc:
        print("Erro de instalação: " + str(exc), file=sys.stderr)
        sys.exit(1)
