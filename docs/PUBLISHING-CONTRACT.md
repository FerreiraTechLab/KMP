# Contrato de publicação do KMP

Status: **candidato estável para a versão 3 do catálogo**.

Este contrato separa os dados enviados por quem mantém um port dos dados que o
KMP Client recebe. O Publisher nunca escreve diretamente no catálogo oficial e
nunca recebe a chave editorial.

```text
Publisher -> submission-v1.json + ZIP -> revisão editorial
          -> artefatos imutáveis -> catalog-v3.json assinado -> Client
```

## Identidades e versões

- `id` identifica o projeto e nunca é reutilizado.
- `portId` identifica a instalação no diretório Ports e nunca é reutilizado.
- `variant.id` é estável dentro do projeto, por exemplo `aarch64-portmaster`.
- `release.version` é o texto mostrado ao usuário. Pode seguir a versão do
  upstream e não é usado para ordenar atualizações.
- `release.revision` é um inteiro positivo, crescente por projeto. O cliente
  oferece atualização apenas quando a revisão publicada é maior que a revisão
  instalada.
- Uma combinação de projeto, revisão e variante é imutável. Corrigir qualquer
  byte exige uma revisão nova.

O manifesto instalado guarda `id`, `portId`, `revision`, `version`,
`variantId`, `packageSha256`, `infoHash` e os caminhos instalados. Isso permite
comparar atualizações sem interpretar versões como `1.0`, `v2-beta` ou datas.

## Proposta do Publisher

O arquivo segue `schemas/publisher-submission-v1.schema.json` e contém:

- identidade do projeto, upstream, código fonte e licença ou expressão de
  licenças;
- identidade e contato público do responsável pelo envio;
- declaração explícita de permissão para redistribuir o pacote;
- versão, revisão, changelog e canal;
- uma ou mais variantes, sua compatibilidade e requisitos;
- caminho local, tamanho e SHA-256 de cada ZIP;
- caminhos de instalação e dados persistentes;
- resultados locais das verificações do Publisher.

Hashes e verificações declarados pelo Publisher são repetidos pela automação
editorial. Magnet, torrent, web seeds e decisão de revisão são produzidos após
o pacote ser aceito.

Cada variante é analisada por `tools/audit-package.py`. Seu relatório segue
`schemas/audit-report-v1.schema.json` e faz parte dos registros da revisão. A
política de reprovações e alertas está em `docs/PORT-SECURITY.md`.

## Catálogo entregue ao Client

O arquivo segue `schemas/catalog-v3.schema.json`. Cada item contém somente uma
release corrente por canal e uma lista de variantes. Cada variante inclui um
pacote imutável e todos os dados necessários para seleção, download e
instalação sem consultar o Publisher.

O cliente estável considera apenas releases com `channel: "stable"` e revisão
maior que a instalada. Canais futuros precisam ser escolhidos explicitamente
pelo usuário.

### Seleção de variante

1. Rejeitar arquitetura diferente.
2. Rejeitar firmware presente em `exclude`.
3. Quando `include` existir, exigir correspondência com o identificador do
   firmware detectado.
4. Rejeitar `requiredCapabilities` que o cliente não conheça.
5. Rejeitar requisitos obrigatórios que o dispositivo não satisfaz.
6. Ordenar as candidatas pelo maior `priority`.
7. Empate entre variantes compatíveis é erro editorial; o cliente não escolhe
   arbitrariamente.

Identificadores de firmware são minúsculos e estáveis, como `darkos`,
`rocknix` e `aurknix`. A arquitetura usa os nomes de `uname -m` normalizados.

### Instalação e dados do usuário

- `install.paths` declara todas as raízes que o pacote pode instalar.
- O ZIP não pode conter arquivos fora dessas raízes.
- `install.userDataPaths` identifica diretórios que devem sobreviver a uma
  atualização, mas são removidos numa desinstalação completa.
- Caminhos são relativos, não aceitam `..`, barra invertida, dois pontos ou
  links simbólicos.
- O cliente mantém a instalação transacional e valida novamente tamanho,
  SHA-256 e estrutura do ZIP.

## Procedência e revisão

Uma assinatura do catálogo autentica a decisão editorial; ela não prova que o
programa seja benigno. Todo item publicado registra:

- upstream e repositório de código fonte;
- licença SPDX, expressão SPDX ou `LicenseRef-*` para pacotes mistos, sempre
  acompanhada de evidência e notas de redistribuição;
- responsável pelo port;
- identificador público da revisão;
- revisor, data e verificações realizadas.

O catálogo oficial aceita apenas `review.status: "approved"`. A revisão deve
recalcular hashes, inspecionar o launcher e o ZIP, conferir a licença e executar
o port em ambiente de teste quando houver hardware compatível.

## Revogação

`revocations` permite impedir novas instalações de um SHA-256 conhecido e
avisar instalações existentes sem apagar dados automaticamente. A ação
`block-install` bloqueia instalação e atualização; `warn` apenas informa. Uma
revogação é parte do snapshot assinado e não depende de tracker ou mirror.

## Compatibilidade do contrato

- Alterações que removam campos, mudem significado ou tornem um campo opcional
  obrigatório exigem uma nova `schemaVersion`.
- Novos campos formais exigem outra `schemaVersion`, pois os validadores são
  estritos. Dados opcionais experimentais ficam em `extensions`, com chaves em namespace reverso,
  por exemplo `org.ferreiratechlab.rating`.
- O cliente ignora extensões desconhecidas. Quando uma extensão passa a ser
  necessária para instalar uma variante, seu identificador entra em
  `requiredCapabilities`; clientes que não a conhecem ocultam apenas essa
  variante.
- Catálogos v2 permanecem aceitos durante a migração. A ativação do v3 só deve
  ocorrer depois que o cliente selecionar variantes, armazenar `revision` e
  aplicar revogações.

## O que fica fora do contrato

- credenciais do GitHub e autenticação do serviço de publicação;
- chave privada editorial;
- votos, avaliações, contagem de downloads e telemetria;
- disponibilidade instantânea de peers;
- configuração local de bateria, upload e armazenamento.

Esses dados mudam independentemente de uma release e não pertencem ao snapshot
imutável.
