#!/usr/bin/env python3
"""Audit a KMP Publisher ZIP without extracting or executing it."""

from __future__ import annotations

import argparse
import hashlib
import json
from datetime import datetime, timezone
from pathlib import Path, PurePosixPath
import re
import stat
import sys
import zipfile


POLICY_VERSION = "1.0"
MAX_ENTRIES = 10_000
MAX_UNPACKED = 8 * 1024 * 1024 * 1024
MAX_ENTRY_SIZE = 2 * 1024 * 1024 * 1024
MAX_RATIO = 1_000
ELF_MACHINES = {40: "armhf", 62: "x86_64", 183: "aarch64"}
SCRIPT_SUFFIXES = {".sh", ".bash"}
LICENSE_NAMES = {"license", "license.txt", "license.md", "copying", "copying.txt"}

SHELL_RULES = (
    ("SYSTEM_WRITE", "error", re.compile(r"(?:>|>>|tee\s+)(?:\s*)/(?:etc|usr|boot)(?:/|\s|$)"),
     "launcher tenta gravar em diretório do sistema"),
    ("DEVICE_WRITE", "error", re.compile(r"\bdd\b[^\n]*\bof=/dev/"),
     "launcher tenta gravar diretamente em dispositivo"),
    ("DEVICE_WRITE", "error", re.compile(r"(?:>|>>|tee\s+)\s*/dev/(?!null(?:\s|$)|tty(?:\s|$))"),
     "launcher tenta gravar diretamente em dispositivo"),
    ("SYSTEM_MUTATION", "error", re.compile(
        r"\b(?:cp|mv|install|rm|chmod|chown|ln)\b[^\n;&|]*\s/(?:etc|usr|boot)(?:/|\s|$)"),
     "launcher tenta alterar diretório do sistema"),
    ("ROOT_DELETE", "error", re.compile(r"\brm\s+(?:-[A-Za-z]*r[A-Za-z]*f|-[A-Za-z]*f[A-Za-z]*r)\s+/(?:\s|$)"),
     "launcher tenta apagar a raiz do sistema"),
    ("REMOTE_SCRIPT", "warning", re.compile(r"\b(?:curl|wget)\b[^\n|;]*(?:\||;)\s*(?:sh|bash)\b"),
     "launcher baixa e executa código remoto"),
    ("NETWORK_DOWNLOAD", "warning", re.compile(r"\b(?:curl|wget|aria2c)\b"),
     "launcher realiza download fora do pacote revisado"),
    ("PACKAGE_MANAGER", "warning", re.compile(r"\b(?:apt|apt-get|dnf|pacman|apk)\s+(?:install|remove|upgrade)\b"),
     "launcher altera pacotes do firmware"),
    ("PRIVILEGE", "warning", re.compile(r"\b(?:sudo|su)\b"),
     "launcher solicita elevação de privilégio"),
    ("SERVICE_CONTROL", "warning", re.compile(r"\b(?:systemctl|service|mount|umount)\b"),
     "launcher altera serviços ou montagens"),
    ("WORLD_WRITABLE", "warning", re.compile(r"\bchmod\s+(?:-R\s+)?777\b"),
     "launcher torna arquivos graváveis por todos"),
    ("DYNAMIC_EVAL", "warning", re.compile(r"\beval\b"),
     "launcher executa texto construído dinamicamente"),
)


def utc_now() -> str:
    return datetime.now(timezone.utc).isoformat(timespec="seconds").replace("+00:00", "Z")


def safe_path(value: str) -> bool:
    if not value or value.startswith("/") or "\\" in value or ":" in value or "//" in value:
        return False
    return all(part not in {"", ".", ".."} for part in value.rstrip("/").split("/"))


def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def sha256_member(archive: zipfile.ZipFile, info: zipfile.ZipInfo) -> str:
    digest = hashlib.sha256()
    with archive.open(info) as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def read_member(archive: zipfile.ZipFile, info: zipfile.ZipInfo, limit: int) -> bytes:
    with archive.open(info) as handle:
        return handle.read(limit)


def elf_architecture(header: bytes) -> str | None:
    if len(header) < 20 or header[:4] != b"\x7fELF":
        return None
    byteorder = "little" if header[5] == 1 else "big" if header[5] == 2 else None
    if byteorder is None:
        return "unknown"
    return ELF_MACHINES.get(int.from_bytes(header[18:20], byteorder), "unknown")


def audit(submission_path: Path, variant_id: str) -> dict:
    submission = json.loads(submission_path.read_text(encoding="utf-8"))
    project = submission["project"]
    variants = submission["release"]["variants"]
    matches = [variant for variant in variants if variant.get("id") == variant_id]
    if len(matches) != 1:
        raise ValueError(f"variante não encontrada ou duplicada: {variant_id}")
    variant = matches[0]
    package_spec, install = variant["package"], variant["install"]
    package_path = (submission_path.parent / package_spec["path"]).resolve()
    base = submission_path.parent.resolve()
    if not package_path.is_relative_to(base):
        raise ValueError("package.path sai do diretório da proposta")

    findings: list[dict] = []
    executables: list[dict] = []

    def finding(code: str, severity: str, message: str, path: str | None = None,
                line: int | None = None) -> None:
        entry = {"code": code, "severity": severity, "message": message}
        if path is not None:
            entry["path"] = path
        if line is not None:
            entry["line"] = line
        findings.append(entry)

    if package_path.is_symlink() or not package_path.is_file():
        raise ValueError(f"pacote não encontrado: {package_path}")
    actual_size = package_path.stat().st_size
    actual_digest = sha256_file(package_path)
    if actual_size != package_spec["sizeBytes"]:
        finding("SIZE_MISMATCH", "error", "tamanho do ZIP diverge da proposta")
    if actual_digest != package_spec["sha256"]:
        finding("HASH_MISMATCH", "error", "SHA-256 do ZIP diverge da proposta")

    declared_paths = install["paths"]
    allowed_roots = {path.rstrip("/").split("/", 1)[0] for path in declared_paths}
    names, unpacked, compressed = set(), 0, 0
    launcher_count = 0
    license_found = False
    try:
        archive = zipfile.ZipFile(package_path)
    except (OSError, zipfile.BadZipFile) as exc:
        finding("INVALID_ZIP", "error", f"ZIP inválido: {exc}")
        archive = None
    if archive is not None:
        with archive:
            entries = archive.infolist()
            if len(entries) > MAX_ENTRIES:
                finding("TOO_MANY_ENTRIES", "error", f"ZIP possui mais de {MAX_ENTRIES} entradas")
            for info in entries:
                name = info.filename.rstrip("/")
                if not safe_path(info.filename):
                    finding("UNSAFE_PATH", "error", "caminho inseguro no ZIP", info.filename)
                    continue
                if name in names:
                    finding("DUPLICATE_PATH", "error", "caminho duplicado no ZIP", name)
                    continue
                names.add(name)
                unpacked += info.file_size
                compressed += info.compress_size
                if info.flag_bits & 1:
                    finding("ENCRYPTED_ENTRY", "error", "entrada criptografada", name)
                if info.file_size > MAX_ENTRY_SIZE:
                    finding("ENTRY_TOO_LARGE", "error", "entrada excede 2 GiB", name)
                root = name.split("/", 1)[0]
                if root not in allowed_roots:
                    finding("UNDECLARED_ROOT", "error", "arquivo fora de install.paths", name)
                mode = info.external_attr >> 16
                file_type = stat.S_IFMT(mode)
                if file_type == stat.S_IFLNK:
                    finding("SYMLINK", "error", "link simbólico não é permitido", name)
                    continue
                if file_type not in (0, stat.S_IFREG, stat.S_IFDIR):
                    finding("SPECIAL_FILE", "error", "arquivo especial não é permitido", name)
                    continue
                if mode & (stat.S_ISUID | stat.S_ISGID):
                    finding("PRIVILEGED_MODE", "error", "bit setuid/setgid não é permitido", name)
                if info.is_dir():
                    continue
                lower_name = PurePosixPath(name).name.lower()
                if lower_name in LICENSE_NAMES:
                    license_found = True
                try:
                    header = read_member(archive, info, 4096)
                except (RuntimeError, zipfile.BadZipFile) as exc:
                    finding("READ_ERROR", "error", f"não foi possível verificar a entrada: {exc}", name)
                    continue
                architecture = elf_architecture(header)
                suffix = PurePosixPath(name).suffix.lower()
                executable = bool(mode & 0o111) or suffix in SCRIPT_SUFFIXES or architecture is not None
                if executable:
                    kind = "elf" if architecture is not None else "shell" if suffix in SCRIPT_SUFFIXES else "file"
                    try:
                        executable_digest = sha256_member(archive, info)
                    except (RuntimeError, zipfile.BadZipFile) as exc:
                        finding("READ_ERROR", "error",
                                f"não foi possível calcular o hash da entrada: {exc}", name)
                    else:
                        executables.append({
                            "path": name, "type": kind,
                            "architecture": architecture,
                            "sha256": executable_digest,
                        })
                if architecture is not None and architecture not in variant["compatibility"]["architectures"]:
                    finding("ELF_ARCH_MISMATCH", "error",
                            f"ELF {architecture} incompatível com a variante", name)
                if suffix in SCRIPT_SUFFIXES:
                    if "/" not in name:
                        launcher_count += 1
                    if info.file_size > 4 * 1024 * 1024:
                        finding("SCRIPT_TOO_LARGE", "error", "script excede 4 MiB", name)
                        continue
                    text = read_member(archive, info, 4 * 1024 * 1024 + 1).decode("utf-8", "replace")
                    first_line = text.splitlines()[0] if text.splitlines() else ""
                    if not first_line.startswith("#!"):
                        finding("MISSING_SHEBANG", "error", "script sem shebang", name, 1)
                    elif not re.match(r"^#!\s*/(?:bin/(?:ba)?sh|usr/bin/env\s+(?:ba)?sh)\s*$", first_line):
                        finding("UNUSUAL_INTERPRETER", "warning", "interpretador não reconhecido", name, 1)
                    for line_number, line in enumerate(text.splitlines(), 1):
                        code = line.split("#", 1)[0]
                        for rule_code, severity, pattern, message in SHELL_RULES:
                            if pattern.search(code):
                                finding(rule_code, severity, message, name, line_number)
            if unpacked > MAX_UNPACKED:
                finding("UNPACKED_TOO_LARGE", "error", "conteúdo extraído excede 8 GiB")
            ratio = unpacked / max(compressed, 1)
            if ratio > MAX_RATIO:
                finding("EXTREME_COMPRESSION", "error", "taxa de compressão sugere ZIP bomb")
            elif ratio > 100:
                finding("HIGH_COMPRESSION", "warning", "taxa de compressão incomum")
            safe_to_expand = (len(entries) <= MAX_ENTRIES and unpacked <= MAX_UNPACKED
                              and ratio <= MAX_RATIO
                              and all(info.file_size <= MAX_ENTRY_SIZE for info in entries))
            if safe_to_expand:
                bad_member = archive.testzip()
                if bad_member:
                    finding("CRC_ERROR", "error", "CRC inválido", bad_member)
    if launcher_count == 0:
        finding("MISSING_LAUNCHER", "error", "nenhum launcher .sh foi encontrado na raiz")
    if not license_found:
        finding("LICENSE_NOT_PACKAGED", "warning",
                "o ZIP não contém LICENSE ou COPYING; conferir a evidência externa")

    severity_order = {"error": 0, "warning": 1, "info": 2}
    findings.sort(key=lambda entry: (severity_order[entry["severity"]], entry.get("path", ""),
                                     entry.get("line", 0), entry["code"]))
    errors = sum(entry["severity"] == "error" for entry in findings)
    warnings = sum(entry["severity"] == "warning" for entry in findings)
    verdict = "reject" if errors else "review" if warnings else "pass"
    return {
        "schemaVersion": 1,
        "policyVersion": POLICY_VERSION,
        "auditedAt": utc_now(),
        "projectId": project["id"],
        "releaseRevision": submission["release"]["revision"],
        "variantId": variant_id,
        "package": {
            "path": package_spec["path"], "sizeBytes": actual_size,
            "sha256": actual_digest, "entries": len(names),
            "unpackedBytes": unpacked,
        },
        "verdict": verdict,
        "summary": {"errors": errors, "warnings": warnings},
        "findings": findings,
        "executables": sorted(executables, key=lambda entry: entry["path"]),
    }


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("submission", type=Path)
    parser.add_argument("--variant", required=True)
    parser.add_argument("--output", type=Path)
    parser.add_argument("--fail-on-warning", action="store_true")
    args = parser.parse_args()
    try:
        report = audit(args.submission.resolve(), args.variant)
    except (OSError, KeyError, TypeError, ValueError, json.JSONDecodeError) as exc:
        parser.exit(2, f"erro: {exc}\n")
    encoded = json.dumps(report, ensure_ascii=False, indent=2) + "\n"
    if args.output:
        args.output.parent.mkdir(parents=True, exist_ok=True)
        args.output.write_text(encoded, encoding="utf-8")
    else:
        sys.stdout.write(encoded)
    if report["summary"]["errors"] or (args.fail_on_warning and report["summary"]["warnings"]):
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
