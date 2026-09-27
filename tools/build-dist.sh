#!/bin/sh
set -eu

repo_dir=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
version=$(cat "$repo_dir/VERSION")
case "$version" in
    ''|*[!0-9.]*) printf 'Versão inválida em VERSION: %s\n' "$version" >&2; exit 1 ;;
esac

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
