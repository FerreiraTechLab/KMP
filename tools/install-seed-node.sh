#!/bin/sh
set -eu

repo_dir=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
release="$repo_dir/build/catalog-release-2"
seed_root=${KMP_SEED_ROOT:-"$HOME/.local/share/kmp-seed"}
unit_dir=${XDG_CONFIG_HOME:-"$HOME/.config"}/systemd/user

command -v aria2c >/dev/null 2>&1 || {
    echo "aria2c não encontrado" >&2
    exit 1
}

for name in catalog-00000002.json catalog-00000002.torrent \
            celeste64-1.1.1.zip celeste64-1.1.1.torrent; do
    test -f "$release/$name" || {
        echo "artefato ausente: $release/$name" >&2
        exit 1
    }
done

mkdir -p "$seed_root/data" "$seed_root/torrents" "$unit_dir"
install -m 0644 "$release/catalog-00000002.json" "$seed_root/data/"
install -m 0644 "$release/celeste64-1.1.1.zip" "$seed_root/data/"
install -m 0644 "$release/catalog-00000002.torrent" "$seed_root/torrents/"
install -m 0644 "$release/celeste64-1.1.1.torrent" "$seed_root/torrents/"
install -m 0644 "$repo_dir/deploy/kmp-seed/kmp-seed.service" \
    "$unit_dir/kmp-seed.service"
touch "$seed_root/session.txt"

systemctl --user daemon-reload
systemctl --user enable --now kmp-seed.service
systemctl --user --no-pager --full status kmp-seed.service
