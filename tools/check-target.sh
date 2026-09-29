#!/bin/sh
# Diagnóstico somente de leitura para o R36H/DarkOS.
set -u

printf 'Sistema: '
uname -a
printf 'Arquitetura: '
uname -m
printf 'libc: '
getconf GNU_LIBC_VERSION 2>/dev/null || printf 'não identificada\n'
printf 'memória: '
awk '/MemTotal/ {print $2 " kB"}' /proc/meminfo 2>/dev/null || true

for tool in aria2c curl unzip love; do
    if command -v "$tool" >/dev/null 2>&1; then
        printf '%s: %s\n' "$tool" "$(command -v "$tool")"
    else
        printf '%s: ausente no PATH\n' "$tool"
    fi
done

script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
repo_dir=$(CDPATH= cd -- "$script_dir/.." && pwd)
bundled="$repo_dir/KMP/libs.$(uname -m)/aria2c"
if [ -f "$bundled" ]; then
    printf 'aria2c empacotado: %s\n' "$(file "$bundled")"
fi

if command -v aria2c >/dev/null 2>&1; then
    aria2c --version | sed -n '1,12p'
fi

if command -v dpkg-query >/dev/null 2>&1; then
    dpkg-query -W -f='${Package} ${Version}\n' libc6 libstdc++6 libaria2-0 aria2 2>/dev/null || true
fi

for path in /roms/ports /roms2/ports; do
    if [ -d "$path" ]; then
        df -h "$path"
    fi
done

for path in /opt/system/Tools/PortMaster /opt/tools/PortMaster /roms/ports/PortMaster; do
    if [ -d "$path" ]; then printf 'PortMaster: %s\n' "$path"; fi
done
