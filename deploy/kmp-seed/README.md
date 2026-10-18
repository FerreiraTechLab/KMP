# Nó público de distribuição KMP

O nó acompanha o catálogo oficial assinado e mantém todos os snapshots e pacotes
aprovados disponíveis por BitTorrent. Consoles e Publishers continuam participando
do swarm, mas não precisam aceitar conexões externas para alcançar este nó.

## Requisitos

- servidor Linux com IPv4 público ou IPv6 acessível;
- Python 3, OpenSSL, aria2 e systemd;
- armazenamento suficiente para todos os pacotes publicados;
- TCP e UDP 6881 liberados no firewall do servidor e do provedor.

Em Debian ou Ubuntu:

```sh
sudo apt update
sudo apt install aria2 openssl python3
sudo ./tools/install-seed-node.sh
sudo ufw allow 6881/tcp
sudo ufw allow 6881/udp
```

Não é necessário copiar torrents manualmente. A cada cinco minutos o serviço:

1. consulta todos os mirrors configurados;
2. verifica a assinatura Ed25519 e a sequência do catálogo;
3. baixa cada pacote ausente por HTTPS e confere tamanho e SHA-256;
4. entrega os torrents incorporados ao catálogo para um único daemon aria2;
5. mantém snapshots e pacotes antigos para não interromper versões ainda usadas.

## Operação

```sh
sudo systemctl status kmp-seed
sudo journalctl -u kmp-seed -f
sudo cat /var/lib/kmp-seed/status.json
```

Os dados e a chave pública rotacionável ficam em `/var/lib/kmp-seed`. A lista de
mirrors fica em `/etc/kmp-seed`.
