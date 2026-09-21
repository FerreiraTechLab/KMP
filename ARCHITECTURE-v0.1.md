# KDownloader v0.1 — contrato e fluxo

## Objetivo

Descobrir, baixar, validar, instalar e compartilhar homebrews por BitTorrent
sem alterar a navegação principal por controle. O catálogo continua sendo uma
fonte configurada; os pacotes passam a vir do swarm.

Alvo inicial: R36H com DarkOS customizado, Debian 13 (trixie) `aarch64`,
kernel 4.4.189, glibc 2.41. O pacote PortMaster já declara suporte a
`aarch64`. O aparelho tem `apt`, `curl` e `unzip`, mas não tinha `aria2c` no PATH
no diagnóstico inicial. Para o protótipo, instalar `aria2` via `apt` no aparelho;
avaliar empacotamento local depois do teste ponta a ponta.

## Catálogo

O documento raiz tem `schemaVersion: 1` e `items`, um array de pacotes.
Cada item contém:

| Campo | Regra |
| --- | --- |
| `id` | Identificador estável, ASCII, `[a-z0-9][a-z0-9_-]*` |
| `name` | Nome exibido, não usado como caminho |
| `version` | Versão exibida |
| `description` | Descrição curta |
| `sizeBytes` | Tamanho inteiro e positivo do pacote |
| `license` | Identificador ou nome da licença de redistribuição |
| `infoHash` | Hash BitTorrent v1 de 40 caracteres hexadecimais |
| `magnet` | URI magnet com `xt=urn:btih:` correspondente a `infoHash` |
| `packageFile` | Nome seguro de um ZIP único, terminado em `.zip` |
| `install` | Identificador do port e lista de caminhos esperados no ZIP |

O cliente rejeita versões de esquema desconhecidas e itens inválidos, sem
construir caminhos ou comandos com texto livre vindo do catálogo. O arquivo
sincronizado é salvo de forma atômica. Se a rede falhar, a última cópia válida
permanece disponível com indicação de modo offline. A URL da fonte fica em
configuração, para permitir mirrors mais tarde.

Exemplo mínimo:

```json
{
  "schemaVersion": 1,
  "items": [
    {
      "id": "example-homebrew",
      "name": "Example Homebrew",
      "version": "1.0",
      "description": "Exemplo de pacote redistribuível",
      "sizeBytes": 1048576,
      "license": "MIT",
      "infoHash": "0123456789abcdef0123456789abcdef01234567",
      "magnet": "magnet:?xt=urn:btih:0123456789abcdef0123456789abcdef01234567",
      "packageFile": "example-homebrew.zip",
      "install": {
        "portId": "example-homebrew",
        "paths": ["example-homebrew.sh", "example-homebrew/"]
      }
    }
  ]
}
```

O exemplo descreve o formato; seu hash não corresponde a um torrent real.

## Componentes

```text
Interface LÖVE (lista, busca, detalhes, progresso, erros)
        │
        ├── Catálogo (sincronização, validação, cache)
        ├── Instalações (manifesto, espaço, extração, remoção)
        └── Transferência (API: iniciar, consultar, pausar, retomar, parar)
                    └── aria2c local (BitTorrent, tracker/DHT, hashes, seeding)
```

A interface recebe estados de transferência independentes do protocolo. O
adaptador `aria2c` usa RPC em loopback com segredo aleatório por sessão. Limites
de memória, peers, taxa de upload e tempo de seeding são configuráveis. O
processo é encerrado ao sair do aplicativo, após registrar seu estado. A
instalação só começa quando o cliente informa download completo e verificado.

## Instalação segura

1. Conferir espaço livre para pacote, extração e margem de segurança antes de
   iniciar. O valor de `sizeBytes` do catálogo é uma estimativa; conferir também
   os tamanhos reais declarados no ZIP.
2. Baixar para uma área temporária persistente por `id` e `infoHash`, permitindo
   retomada. Um download parcial nunca cria manifesto de instalação.
3. Confirmar o `infoHash` e a verificação das peças pelo cliente torrent.
4. Inspecionar cada entrada do ZIP: rejeitar caminhos absolutos, `..`, links,
   caminhos fora do conjunto esperado e colisões com outros ports.
5. Extrair em staging no mesmo volume do destino, validar os arquivos e mover
   para o diretório de ports. Registrar manifesto com `id`, versão, hash,
   destino e caminhos efetivamente instalados.
6. Remover somente os caminhos registrados no manifesto daquele `id`. Ports
   anteriores sem manifesto são mostrados, mas exigem migração explícita para
   permitir remoção segura.

## Estado da implementação

- O catálogo v1 é validado em `catalog.lua`; a interface usa busca por nome,
  detalhes e cache local. A prévia usa o catálogo demo incluído, substituível
  por `KMP/catalog-url.txt`.
- `torrent.lua` e `aria2_rpc.lua` controlam o `aria2c` instalado no DarkOS.
  O launcher inicia o processo em loopback e limita o upload a 100 KiB/s.
- `KMP/install.py` valida o ZIP, extrai em staging e cria o manifesto. O
  desinstalador usa esse manifesto; ports antigos ficam para remoção manual.
- Testes locais cobrem validação, transporte RPC e instalação. O cenário com
  dois portáteis e um PC ainda precisa ser executado no hardware real.

## Dependências a confirmar no hardware alvo

- Bibliotecas do DarkOS, memória disponível e versão do runtime LÖVE.
- `aria2c` 1.37.0 e Python 3.13.5 foram confirmados no R36H. O launcher usa
  esses programas do sistema; um binário empacotado pode ser incluído depois.
- Caminhos reais e espaço dos cartões; política de seeding e limite de upload.
- Um homebrew cujo autor permita redistribuição para o teste ponta a ponta.

O `game.love` deve ser recompacotado a partir de `KMP/game/` após cada mudança
de código; alterar apenas a pasta de fontes não altera o aplicativo distribuído.
