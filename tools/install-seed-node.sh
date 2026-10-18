#!/bin/sh
set -eu

repo_dir=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)

if [ "$(id -u)" -ne 0 ]; then
    echo "execute como root: sudo $0" >&2
    exit 1
fi

for command_name in python3 openssl systemctl; do
    command -v "$command_name" >/dev/null 2>&1 || {
        echo "dependência ausente: $command_name" >&2
        exit 1
    }
done

torrentd_binary="$repo_dir/build/torrentd/kmp-torrentd-linux-amd64"
[ -x "$torrentd_binary" ] || {
    echo "binário ausente: execute tools/build-torrentd.sh antes da instalação" >&2
    exit 1
}

getent group kmp-seed >/dev/null 2>&1 || groupadd --system kmp-seed
getent passwd kmp-seed >/dev/null 2>&1 || useradd --system --gid kmp-seed \
    --home-dir /var/lib/kmp-seed --shell /usr/sbin/nologin kmp-seed

install -d -m 0755 /usr/local/lib/kmp-seed /etc/kmp-seed
install -d -o kmp-seed -g kmp-seed -m 0700 /var/lib/kmp-seed
install -m 0755 "$repo_dir/deploy/kmp-seed/kmp_seed_node.py" \
    /usr/local/lib/kmp-seed/kmp_seed_node.py
install -m 0755 "$torrentd_binary" /usr/local/lib/kmp-seed/kmp-torrentd
install -m 0644 "$repo_dir/KMP/catalog_security.py" \
    /usr/local/lib/kmp-seed/catalog_security.py
install -m 0644 "$repo_dir/KMP/catalog_sync.py" \
    /usr/local/lib/kmp-seed/catalog_sync.py
if [ ! -f /var/lib/kmp-seed/catalog-root.pub ]; then
    install -o kmp-seed -g kmp-seed -m 0600 "$repo_dir/KMP/catalog-root.pub" \
        /var/lib/kmp-seed/catalog-root.pub
fi
install -m 0644 "$repo_dir/KMP/catalog-sources.txt" /etc/kmp-seed/catalog-sources.txt
install -m 0644 "$repo_dir/deploy/kmp-seed/kmp-seed.service" \
    /etc/systemd/system/kmp-seed.service

systemctl daemon-reload
systemctl enable --now kmp-seed.service
systemctl --no-pager --full status kmp-seed.service

cat <<'EOF'

Nó instalado. Libere no firewall e no provedor:
  TCP 6881
  UDP 6881

Diagnóstico:
  systemctl status kmp-seed
  journalctl -u kmp-seed -f
  cat /var/lib/kmp-seed/status.json
EOF
