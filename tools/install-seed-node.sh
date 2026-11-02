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

case "$(uname -m)" in
    x86_64|amd64) torrentd_arch=amd64 ;;
    aarch64|arm64) torrentd_arch=arm64 ;;
    *) echo "arquitetura sem binário do kmp-torrentd: $(uname -m)" >&2; exit 1 ;;
esac
torrentd_binary="$repo_dir/build/torrentd/kmp-torrentd-linux-$torrentd_arch"
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

# Imagens Ubuntu da Oracle Cloud trazem regras iptables que rejeitam toda entrada
# além do SSH; sem estas exceções o nó nunca recebe peers.
if [ -f /etc/iptables/rules.v4 ] && command -v netfilter-persistent >/dev/null 2>&1; then
    for protocol in tcp udp; do
        iptables -C INPUT -p "$protocol" --dport 6881 -j ACCEPT 2>/dev/null ||
            iptables -I INPUT 1 -p "$protocol" --dport 6881 -j ACCEPT
        if [ -f /etc/iptables/rules.v6 ]; then
            ip6tables -C INPUT -p "$protocol" --dport 6881 -j ACCEPT 2>/dev/null ||
                ip6tables -I INPUT 1 -p "$protocol" --dport 6881 -j ACCEPT
        fi
    done
    netfilter-persistent save
fi

# KMP_SEED_KEEPALIVE=1 mantém uma carga ociosa de CPU para que provedores como a
# Oracle Cloud não recuperem a instância gratuita por ociosidade.
if [ "${KMP_SEED_KEEPALIVE:-0}" = 1 ]; then
    install -m 0644 "$repo_dir/deploy/kmp-seed/kmp-keepalive.service" \
        /etc/systemd/system/kmp-keepalive.service
fi

systemctl daemon-reload
systemctl enable --now kmp-seed.service
if [ "${KMP_SEED_KEEPALIVE:-0}" = 1 ]; then
    systemctl enable --now kmp-keepalive.service
fi
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
