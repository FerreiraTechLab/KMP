# Runtime portátil do KMP

Sistemas imutáveis como Rocknix não oferecem `apt` ao usuário. O KMP não deve
alterar o sistema operacional para obter suas dependências. Seguindo o modelo
do PortMaster, ferramentas específicas do port ficam em `KMP/libs.<arch>/`.

## Dependências em tempo de execução

| Componente | Origem | Estratégia |
| --- | --- | --- |
| `aria2c` | KMP | binário estático fixado e verificado em `libs.aarch64/` |
| Python 3 | firmware/PortMaster | usado pelos validadores e instalador |
| `curl` | firmware/PortMaster | transporte local do RPC na interface LÖVE |
| `openssl` | firmware | verificação Ed25519 do catálogo |
| LÖVE 11.5 | runtime PortMaster | montado pelo launcher existente |

O `aria2c` empacotado usa musl e incorpora suas bibliotecas de rede e TLS. Não
empacotamos libc, SDL, Mesa nem drivers gráficos do firmware. Isso evita os
conflitos que o próprio PortMaster alerta ao misturar bibliotecas centrais de
distribuições diferentes.

## Processo de build

`tools/fetch-runtime-deps.sh aarch64` baixa o artefato fixado, compara o
SHA-256 antes de extrair e grava somente `aria2c`. `tools/build-dist.sh` recusa
gerar uma distribuição se esse binário estiver ausente, tiver arquitetura
incorreta ou não for executável.

Novas arquiteturas exigem uma entrada própria com URL, hash, teste em hardware
e atualização de `port.json`. Um binário obtido do PATH permanece apenas como
fallback de desenvolvimento.
