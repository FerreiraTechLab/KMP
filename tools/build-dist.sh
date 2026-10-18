#!/bin/sh
set -eu

repo_dir=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
version=$(cat "$repo_dir/VERSION")
case "$version" in
    ''|*[!0-9.]*) printf 'Versão inválida em VERSION: %s\n' "$version" >&2; exit 1 ;;
esac

bundled_aria2="$repo_dir/KMP/libs.aarch64/aria2c"
bundled_torrentd="$repo_dir/KMP/libs.aarch64/kmp-torrentd"
if [ ! -x "$bundled_aria2" ]; then
    printf 'aria2c portátil ausente. Execute: tools/fetch-runtime-deps.sh aarch64\n' >&2
    exit 1
fi
if [ ! -x "$bundled_torrentd" ]; then
    printf 'kmp-torrentd portátil ausente. Execute: tools/build-torrentd.sh\n' >&2
    exit 1
fi
if ! file "$bundled_torrentd" | grep -q 'ARM aarch64'; then
    printf 'kmp-torrentd portátil não é um ELF aarch64 válido\n' >&2
    exit 1
fi
if ! file "$bundled_aria2" | grep -q 'ARM aarch64'; then
    printf 'aria2c portátil não é um ELF aarch64 válido\n' >&2
    exit 1
fi
expected_aria2=99a057bd383a28f1d5fab6e8cc5f6f3ed4172f5e65c59548242e965454d654c1
actual_aria2=$(sha256sum "$bundled_aria2" | awk '{print $1}')
if [ "$actual_aria2" != "$expected_aria2" ]; then
    printf 'SHA-256 do aria2c portátil não confere\n' >&2
    exit 1
fi

mkdir -p "$repo_dir/dists"
printf 'return "%s"\n' "$version" > "$repo_dir/KMP/game/version.lua"
printf '%s\n' "$version" > "$repo_dir/KMP/version.txt"
(
    cd "$repo_dir/KMP/game"
    zip -q -r ../game.love .
)
(
    cd "$repo_dir"
    zip -q -r "dists/KMP-v${version}.zip" KMP.sh KMP \
        -x 'KMP/game/*' 'KMP/__pycache__/*'
)
unzip -t "$repo_dir/dists/KMP-v${version}.zip" >/dev/null
printf 'Distribuição criada: dists/KMP-v%s.zip\n' "$version"
