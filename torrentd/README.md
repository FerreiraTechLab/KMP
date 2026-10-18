# kmp-torrentd

Daemon BitTorrent portátil do KMP. Ele oferece, apenas em `127.0.0.1`, o
subconjunto da API JSON-RPC do aria2 usado pelo KMP Client e pelo KMP
Publisher. A implementação usa uma pilha BitTorrent com DHT IPv4/IPv6, PEX,
uTP e hole punching (BEP 55). O daemon usa descoberta e conexão compatíveis
com clientes BitTorrent externos: trackers, DHT, PEX e descoberta local.

O aria2 continuará disponível como fallback durante a migração.
