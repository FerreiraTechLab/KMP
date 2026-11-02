# Nó público de distribuição KMP

O nó acompanha o catálogo oficial assinado e mantém todos os snapshots e pacotes
aprovados disponíveis por BitTorrent. Consoles e Publishers continuam participando
do swarm, mas não precisam aceitar conexões externas para alcançar este nó.

Como o nó é alcançável, ele também apresenta peers atrás de NAT uns aos outros
(hole punching, BEP 55): dois consoles conectados a ele abrem uma conexão direta
entre si, e os bytes dos pacotes não passam pelo servidor. Por isso o daemon do
nó aceita até 200 conexões por torrent, contra 12 nos handhelds.

## Requisitos

- servidor Linux x86_64 ou aarch64 com IPv4 público ou IPv6 acessível;
- Python 3, OpenSSL e systemd;
- `build/torrentd/kmp-torrentd-linux-<arquitetura>` gerado por
  `tools/build-torrentd.sh` (pode ser copiado de outra máquina);
- armazenamento suficiente para todos os pacotes publicados;
- TCP e UDP 6881 liberados no firewall do servidor e do provedor.

Em Debian ou Ubuntu:

```sh
sudo apt update
sudo apt install openssl python3
sudo ./tools/install-seed-node.sh
```

Em imagens Ubuntu da Oracle Cloud, o instalador abre a porta 6881 no iptables
da instância. Também é preciso adicionar uma regra de entrada na Security List
da VCN: origem `0.0.0.0/0`, TCP e UDP, porta de destino 6881. Em outros
provedores com `ufw`, use `sudo ufw allow 6881/tcp` e `sudo ufw allow 6881/udp`.

Não é necessário copiar torrents manualmente. A cada cinco minutos o serviço:

1. consulta todos os mirrors configurados;
2. verifica a assinatura Ed25519 e a sequência do catálogo;
3. baixa por HTTPS cada pacote hospedado nos mirrors e confere tamanho e SHA-256;
4. entrega os torrents incorporados ao catálogo para um único kmp-torrentd, que
   obtém pelo swarm e pelos webseeds os pacotes grandes demais para os mirrors;
5. mantém snapshots e pacotes antigos para não interromper versões ainda usadas.

## Operação

```sh
sudo systemctl status kmp-seed
sudo journalctl -u kmp-seed -f
sudo cat /var/lib/kmp-seed/status.json
```

`packagesFromSwarm` em `status.json` lista os pacotes obtidos pelo torrent em
vez dos mirrors. Os dados e a chave pública rotacionável ficam em
`/var/lib/kmp-seed`. A lista de mirrors fica em `/etc/kmp-seed`.

O nó também semeia submissões em revisão permitidas por
`submission-seeding.json` no KMP-catalog (autores confiáveis ou PRs com o rótulo
configurado). O estado delas fica em `/var/lib/kmp-seed/submissions.json`.

## Monitoramento e recuperação

O repositório privado `kmp-port-probe` roda o workflow `Seed node monitor` a
cada seis horas: ele lê `seed-nodes.json` e o `head.json` do catálogo e exige que
cada nó responda por TCP, DHT e uTP e semeie o torrent do catálogo atual. Se um
nó continuar fora após três tentativas, o workflow falha e o GitHub avisa por
e-mail.

A Oracle Cloud pode recuperar instâncias Always Free ociosas (CPU e rede abaixo
de 20% no percentil 95 por 7 dias). Se o aviso chegar:

1. crie uma instância nova (Ubuntu, sub-rede pública com IPv4 público);
2. libere TCP e UDP 6881 na Security List da sub-rede;
3. gere os binários (`tools/build-torrentd.sh`) e rode
   `tools/deploy-seed-node.sh <ip> <chave-ssh>`;
4. se o IP mudou, atualize `seed-nodes.json` no KMP-catalog. O push publica uma
   nova sequência do catálogo, e os clientes passam a usar o endereço novo.
