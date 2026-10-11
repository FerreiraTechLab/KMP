# Validação em hardware

## R36H — DarkOS — 2026-10-11

Dispositivo identificado pelo sistema como `rg351mp`, arquitetura `aarch64`,
kernel `4.4.189`, Debian 13 e Python 3.13.5. Cliente testado: KMP v0.2.30.

### Restauração da sessão aria2

O diagnóstico foi exportado antes e depois de reiniciar o console pelo menu do
KMP.

| Medida | Antes | Depois |
|---|---:|---:|
| PID do aria2 | 15689 | 8880 |
| Torrents ativos | 8 | 8 |
| Torrents semeando | 8 | 8 |
| Torrents pausados | 0 | 0 |

O PID diferente confirma um novo processo. A recuperação dos oito torrents
ativos confirma que a sessão persistente foi carregada após o reinício.

### Política de bateria

Para testar sem descarregar o aparelho até 29%, o limite foi alterado
temporariamente de 30% para 100%. Com a bateria em 86%, após o reinício e um
intervalo superior a 15 segundos, o monitor apresentou:

| Medida | Limite temporário | Limite restaurado |
|---|---:|---:|
| Limite de bateria | 100% | 30% |
| Bateria | 86% | 86% |
| Torrents semeando | 0 | 8 |
| Torrents pausados | 8 | 0 |
| Registros em `battery-paused.json` | 8 | 0 |

Após restaurar o limite para 30% e reiniciar, todos os torrents pausados pelo
monitor foram retomados automaticamente. O teste confirma pausa abaixo do
limite e retomada quando a bateria volta à faixa permitida.

O único erro apresentado pelo diagnóstico pertence ao histórico de uma
transferência encerrada (`stopped`) e não afetou o daemon nem os oito seeds.
