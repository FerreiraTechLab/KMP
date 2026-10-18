# Matriz de testes de rede

Execute cada cenário por pelo menos cinco minutos e faça uma captura no início,
no meio e no fim. O arquivo JSONL registra bateria, velocidades, peers locais e
remotos, web seeds, CPU acumulada e memória residente do aria2.

```sh
python3 network_metrics.py \
  --rpc "$KMP_ARIA2_RPC" --secret "$KMP_ARIA2_SECRET" \
  --pid "$(cat conf/daemon/pid)" --scenario local-peer \
  --output conf/network-metrics.jsonl
```

Repita com `web-seed`, `remote-peer`, `no-seed` e `nat-restricted`. No último
cenário, bloqueie a porta BitTorrent de entrada no roteador ou firewall e
registre essa condição no relatório. O rótulo descreve a condição controlada;
o cliente não afirma detectar o tipo de NAT apenas pela ausência de conexões.

Para cada execução, anote também o tempo mostrado entre iniciar o download e a
primeira alteração de `completedBytes`. Compare mediana de velocidade, memória
máxima, diferença de `cpuTicks`, queda de bateria e número de peers. Preserve o
JSONL original junto da versão do KMP e do firmware testados.

## Resultado confirmado em hardware

Em 18 de outubro de 2026, o KMP Client concluiu e instalou um port recebido por
BitTorrent com o Publisher em outro roteador do mesmo prédio. O Client mostrou
duas conexões de peer durante a transferência. O teste validou descoberta,
transferência, verificação e instalação entre duas redes distintas usando o
modo de nó comunitário.
