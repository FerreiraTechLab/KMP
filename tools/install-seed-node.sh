#!/bin/sh
set -eu

repo_dir=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
latest_catalog_release="$repo_dir/build/catalog-release-6"
catalog_release="$repo_dir/build/catalog-release-5"
previous_catalog_release="$repo_dir/build/catalog-release-4"
package_release="$repo_dir/build/catalog-release-2"
seed_root=${KMP_SEED_ROOT:-"$HOME/.local/share/kmp-seed"}
unit_dir=${XDG_CONFIG_HOME:-"$HOME/.config"}/systemd/user

command -v aria2c >/dev/null 2>&1 || {
    echo "aria2c não encontrado" >&2
    exit 1
}

for name in catalog-00000006.json catalog-00000006.torrent; do
    test -f "$latest_catalog_release/$name" || {
        echo "artefato ausente: $latest_catalog_release/$name" >&2
        exit 1
    }
done

for name in catalog-00000005.json catalog-00000005.torrent \
            kmp-update-test-2.0.zip kmp-update-test-2.0.torrent; do
    test -f "$catalog_release/$name" || {
        echo "artefato ausente: $catalog_release/$name" >&2
        exit 1
    }
done
for name in catalog-00000004.json catalog-00000004.torrent \
            kmp-update-test-1.0.zip kmp-update-test-1.0.torrent; do
    test -f "$previous_catalog_release/$name" || {
        echo "artefato ausente: $previous_catalog_release/$name" >&2
        exit 1
    }
done
for name in celeste64-1.1.1.zip celeste64-1.1.1.torrent; do
    test -f "$package_release/$name" || {
        echo "artefato ausente: $package_release/$name" >&2
        exit 1
    }
done

mkdir -p "$seed_root/data" "$seed_root/torrents" "$unit_dir"
install -m 0644 "$previous_catalog_release/catalog-00000004.json" "$seed_root/data/"
install -m 0644 "$catalog_release/catalog-00000005.json" "$seed_root/data/"
install -m 0644 "$latest_catalog_release/catalog-00000006.json" "$seed_root/data/"
install -m 0644 "$package_release/celeste64-1.1.1.zip" "$seed_root/data/"
install -m 0644 "$previous_catalog_release/kmp-update-test-1.0.zip" "$seed_root/data/"
install -m 0644 "$catalog_release/kmp-update-test-2.0.zip" "$seed_root/data/"
install -m 0644 "$previous_catalog_release/catalog-00000004.torrent" "$seed_root/torrents/"
install -m 0644 "$catalog_release/catalog-00000005.torrent" "$seed_root/torrents/"
install -m 0644 "$latest_catalog_release/catalog-00000006.torrent" "$seed_root/torrents/"
install -m 0644 "$package_release/celeste64-1.1.1.torrent" "$seed_root/torrents/"
install -m 0644 "$previous_catalog_release/kmp-update-test-1.0.torrent" "$seed_root/torrents/"
install -m 0644 "$catalog_release/kmp-update-test-2.0.torrent" "$seed_root/torrents/"
install -m 0644 "$repo_dir/deploy/kmp-seed/kmp-seed.service" \
    "$unit_dir/kmp-seed.service"
touch "$seed_root/session.txt"

systemctl --user daemon-reload
systemctl --user enable kmp-seed.service
systemctl --user restart kmp-seed.service
systemctl --user --no-pager --full status kmp-seed.service
