#!/bin/sh
# Instala ou atualiza o nó público em um servidor Linux acessível por SSH.
# Uso: tools/deploy-seed-node.sh <host> <chave-ssh> [usuário]
# Com KMP_SEED_KEEPALIVE=1, também liga a carga de CPU contra recuperação por ociosidade.
set -eu

[ $# -ge 2 ] || { echo "uso: $0 <host> <chave-ssh> [usuário]" >&2; exit 1; }
host=$1
key=$2
user=${3:-ubuntu}
repo_dir=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
ssh_options="-i $key -o BatchMode=yes -o StrictHostKeyChecking=accept-new"

case "$(ssh $ssh_options "$user@$host" uname -m)" in
    x86_64|amd64) arch=amd64 ;;
    aarch64|arm64) arch=arm64 ;;
    *) echo "arquitetura do servidor sem binário do kmp-torrentd" >&2; exit 1 ;;
esac
binary="build/torrentd/kmp-torrentd-linux-$arch"
[ -x "$repo_dir/$binary" ] || {
    echo "binário ausente: execute tools/build-torrentd.sh antes da implantação" >&2
    exit 1
}

bundle=$(mktemp)
trap 'rm -f "$bundle"' EXIT
(cd "$repo_dir" && tar --exclude=__pycache__ -czf "$bundle" tools/install-seed-node.sh \
    deploy/kmp-seed KMP/catalog_security.py KMP/catalog_sync.py KMP/catalog-root.pub \
    KMP/catalog-sources.txt "$binary")
scp $ssh_options -q "$bundle" "$user@$host:/tmp/kmp-seed-bundle.tgz"
remote='set -e
rm -rf ~/kmp-seed && mkdir ~/kmp-seed && tar -xzf /tmp/kmp-seed-bundle.tgz -C ~/kmp-seed
sudo KMP_SEED_KEEPALIVE="$keepalive" sh ~/kmp-seed/tools/install-seed-node.sh >/dev/null
sudo systemctl restart kmp-seed
for attempt in $(seq 1 60); do sudo test -f /var/lib/kmp-seed/status.json && break; sleep 5; done
sudo cat /var/lib/kmp-seed/status.json'
case "${KMP_SEED_KEEPALIVE:-0}" in 0|1) ;; *) echo "KMP_SEED_KEEPALIVE deve ser 0 ou 1" >&2; exit 1 ;; esac
ssh $ssh_options "$user@$host" "keepalive=${KMP_SEED_KEEPALIVE:-0}; $remote"

cat <<EOF

Nó implantado em $host. Se for um servidor novo:
  1. libere TCP e UDP 6881 no firewall do provedor (na Oracle, a Security List da VCN);
  2. se o IP mudou, atualize seed-nodes.json no KMP-catalog: o push publica um novo catálogo.
EOF
