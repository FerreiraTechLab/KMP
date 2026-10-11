# KDownloader PM v0.2 — rede e catálogo distribuído

## Objetivos

1. Um console que concluiu um pacote deve continuar semeando para consoles em
   outras redes, dentro dos limites configurados pelo usuário.
2. O catálogo deve continuar disponível quando um mirror cair e seu conteúdo
   deve ser autenticado antes de ser exibido ou usado para instalar arquivos.
3. Um peer, tracker ou mirror comprometido não pode publicar jogos nem fazer o
   cliente voltar para um catálogo antigo.

## Limites do modelo

BitTorrent distribui dados, mas não decide qual catálogo é legítimo ou qual
snapshot é o mais recente. Essa decisão usa uma chave editorial confiável que
vem no aplicativo. Na v0.2 há uma chave raiz. O formato reserva espaço para
rotação de chave e assinaturas múltiplas em uma versão futura.

Trackers e DHT só apresentam peers. Eles não armazenam os pacotes e não são
fontes de confiança. A rede precisa de pelo menos um seeder alcançável para
cada torrent. Consoles ajudam a capacidade da rede, mas não substituem o seeder
inicial enquanto todos estiverem desligados ou atrás de NAT restritivo.

## Publicação do catálogo

Cada publicação cria dois artefatos imutáveis:

```text
catalog-00000042.json
catalog-00000042.json.sig
```

O JSON mantém o esquema dos itens da v1 e acrescenta metadados no documento
raiz:

```json
{
  "schemaVersion": 2,
  "sequence": 42,
  "generatedAt": "2026-09-26T23:00:00Z",
  "items": []
}
```

`sequence` é um inteiro crescente. A assinatura é feita sobre os bytes exatos
do arquivo JSON. O cliente não reserializa o documento antes da verificação.

O snapshot é empacotado como o único arquivo de um torrent. A assinatura fica
incorporada ao head e também é publicada separadamente para auditoria. O
infohash e o hash SHA-256 são publicados em um documento pequeno chamado
`head.json`:

```json
{
  "schemaVersion": 1,
  "sequence": 42,
  "catalogSize": 123456,
  "catalogSha256": "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef",
  "catalogMagnet": "magnet:?xt=urn:btih:...",
  "catalogSignature": "BASE64",
  "publishedAt": "2026-09-26T23:00:00Z",
  "expiresAt": "2026-10-26T23:00:00Z"
}
```

`head.json` também recebe uma assinatura destacada `head.json.sig`. O mesmo par
é copiado para vários endpoints configurados no aplicativo, por exemplo um site
estático, releases de um repositório e mirrors comunitários. Todos podem servir
os mesmos bytes; nenhum mirror possui a chave privada.

## Algoritmo de atualização

1. Buscar `head.json` e `head.json.sig` de todos os endpoints configurados.
2. Limitar tamanho, tempo e redirecionamentos antes de processar respostas.
3. Verificar a assinatura com a chave pública embutida.
4. Rejeitar validade expirada, esquema desconhecido e `sequence` menor que a
   maior sequência já aceita pelo aparelho.
5. Escolher o head válido com maior `sequence`.
6. Se ele já estiver no cache, usar a cópia verificada.
7. Baixar o snapshot pelo magnet usando aria2, DHT, PEX e trackers.
8. Conferir tamanho, SHA-256, assinatura e esquema do catálogo.
9. Gravar o snapshot e o número aceito de forma atômica.
10. Manter o torrent do snapshot ativo para distribuí-lo a outros consoles.

Se todas as fontes falharem, o KMP abre o último snapshot válido e mostra modo
offline. Uma falha nunca apaga o cache válido.

## Atualização do KMP Client

O próprio Client é publicado no catálogo assinado com o identificador reservado
`kmp-client`. Seu pacote contém exatamente `KMP.sh` e `KMP/`; ele usa o mesmo
torrent, web seeds, SHA-256, revisão editorial e revogações dos ports. O item
fica fora da lista de jogos e aparece como ação no menu quando sua versão é
maior que a versão em execução.

O Client baixa e valida o ZIP enquanto a interface ainda está aberta, mas não
substitui arquivos carregados. A versão nova é extraída para
`/roms/ports/.kmp/client-update/`, e uma cópia independente do atualizador fica
em `/roms/ports/.kmp/client-updater.py`. Após a interface encerrar, o launcher:

1. grava um journal e uma cópia da versão atual;
2. troca `KMP/` e `KMP.sh` pela versão preparada;
3. preserva `conf/`, `diagnostics/`, `peer.txt` e `catalog-url.txt`;
4. confirma a transação apenas após sincronizar os arquivos e diretórios.

Se houver queda de energia, a próxima abertura executa o atualizador externo
antes de carregar qualquer arquivo de `KMP/`. Uma transação ainda não confirmada
é revertida; uma transação confirmada mantém a versão nova e apenas conclui a
limpeza. A primeira versão que inclui este mecanismo precisa ser instalada
manualmente uma única vez.

## Autenticidade e rotação de chave

- A chave privada de publicação nunca entra no aplicativo nem no repositório.
- A chave pública raiz é instalada com o KMP.
- Arquivos locais podem configurar chaves adicionais para catálogos
  comunitários separados; itens de autoridades diferentes não são mesclados
  silenciosamente.
- Uma rotação futura deve ser autorizada por uma assinatura da chave atual e
  ter sequência maior. Recuperação após perda da chave exige uma atualização
  do próprio aplicativo.
- O cliente armazena a maior sequência aceita para impedir downgrade por um
  mirror que reproduza uma publicação antiga ainda corretamente assinada.

## Daemon BitTorrent

O cliente distribui `aria2c` estático dentro de `libs.aarch64/`. Isso permite
usar BitTorrent em firmwares imutáveis como Rocknix sem `apt` ou alterações na
partição do sistema. O launcher prefere esse executável e mantém o aria2 do
sistema apenas como fallback. Dependências centrais de vídeo, SDL e libc do
firmware não são substituídas.

O aria2 deixa de pertencer ao processo da interface:

```text
Inicialização do KMP
        │
        ├── encontra daemon existente e conecta por RPC
        └── ou inicia daemon persistente
                 ├── restaura session.txt
                 ├── baixa pacotes e snapshots
                 ├── semeia downloads concluídos
                 └── salva a sessão periodicamente
```

Estado proposto em `/roms/ports/KMP/conf/daemon/`:

| Arquivo | Conteúdo |
| --- | --- |
| `pid` | PID do processo validado antes do uso |
| `rpc.env` | endpoint e segredo RPC, modo `0600` |
| `session.txt` | torrents retomados pelo aria2 |
| `aria2.log` | log rotacionado do daemon |
| `settings.conf` | limites escolhidos pelo usuário |

Configuração inicial:

- RPC somente em `127.0.0.1` com segredo aleatório persistente.
- DHT IPv4, PEX e LPD habilitados.
- Porta BitTorrent fixa configurável para permitir encaminhamento no roteador.
- Upload padrão de 100 KiB/s.
- Sessão salva a cada 30 segundos e após inclusão de um torrent.
- Pacotes concluídos continuam semeando enquanto o aparelho estiver ligado.
- A interface oferece pausar todos os seeds e encerrar o daemon.

Uma integração de boot é específica do firmware e fica fora do primeiro corte
da v0.2. Ao abrir o KMP após reiniciar o aparelho, a sessão é restaurada e os
seeds voltam automaticamente.

## Catálogo de bootstrap

O pacote do KMP inclui um snapshot pequeno e assinado para a primeira abertura.
Ele contém apenas conteúdo redistribuível e pelo menos dois mecanismos de
descoberta por torrent. O tracker local usado na v0.1.7 permanece em `tools/`
como teste de integração e não participa da rede de produção.

## Entregas da v0.2

1. Gerador e verificador de snapshots e heads assinados.
2. Validador do esquema de catálogo 2 e proteção contra downgrade.
3. Sincronizador com múltiplos endpoints e cache atômico.
4. Gerenciador do daemon aria2 e sessão persistente.
5. Tela de seeds com estado, upload, proporção e ações de pausa/retomada.
6. Teste entre redes diferentes usando um seeder inicial alcançável.
