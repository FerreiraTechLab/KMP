# Roadmap do KMP

## Decisão de produto

O projeto possui três componentes com públicos diferentes:

1. **KMP Client** — aplicativo usado no console para descobrir, instalar,
   remover, atualizar e semear ports.
2. **KMP Catalog** — catálogo público, versionado e assinado consumido pelo
   cliente.
3. **KMP Publisher** — futura ferramenta para desenvolvedores prepararem uma
   proposta de publicação.

O trabalho atual está concentrado no **KMP Client**. O KMP Publisher será apenas
planejado até as lacunas prioritárias do cliente serem fechadas.

## Experiência do usuário

O usuário do KMP Client não precisa conhecer BitTorrent, Ed25519, fingerprints
ou o processo editorial para instalar um port. O fluxo padrão usa mensagens
simples como catálogo verificado, baixando, instalado, semeando e pausado.

Informações como sequência, validade, fingerprint e estado dos mirrors
continuam disponíveis em uma tela técnica opcional para diagnóstico e
auditoria.

## Lacunas prioritárias do KMP Client

### P0 — integridade da instalação

- [x] Criar journal persistente para instalações.
- [x] Registrar os estados `prepared`, `moving` e `committed`.
- [x] Recuperar ou reverter automaticamente uma instalação interrompida por
      queda de energia.
- [x] Fazer `fsync` dos arquivos e diretórios importantes antes do commit.
- [x] Testar interrupção após cada etapa da instalação.

Critério de conclusão: após desligamento forçado em qualquer etapa, a próxima
execução deixa o port completamente instalado ou completamente removido, sem
estado parcial silencioso.

### P0 — confiança e recuperação

- [x] Definir e implementar rotação de chave autorizada pela chave atual.
- [x] Definir recuperação após comprometimento ou perda da chave.
- [x] Documentar armazenamento e backup offline da chave editorial.
- [x] Tratar relógio incorreto sem aceitar heads expirados silenciosamente.

Critério de conclusão: o cliente consegue distinguir atualização normal,
rotação autorizada, catálogo expirado e relógio inválido, mantendo o último
snapshot aceito quando for seguro.

### P1 — contrato formal do catálogo

- [x] Publicar um JSON Schema para o catálogo e para o head.
- [x] Executar a validação no CI do KMP Catalog.
- [x] Adicionar `packageSha256` a cada pacote.
- [ ] Preparar variantes por firmware, arquitetura e requisitos de hardware.
- [x] Manter compatibilidade explícita com o schema 2 durante a migração.

Critério de conclusão: uma proposta inválida é rejeitada antes de chegar à
assinatura e o cliente escolhe apenas pacotes compatíveis com o dispositivo.

### P1 — rede e mirrors

- [x] Remover ou publicar corretamente o mirror de GitHub Releases.
- [x] Mostrar quantidade de mirrors saudáveis, além dos configurados.
- [x] Medir web seed, peer local, peer remoto, ausência de seed e NAT restritivo.
- [x] Registrar tempo de descoberta, velocidade, CPU, memória, bateria e upload.
- [x] Definir comportamento e mensagem quando todos os mecanismos falharem.

Critério de conclusão: uma matriz reproduzível demonstra quando o BitTorrent
ajuda, quanto custa ao dispositivo e como o cliente degrada para HTTP.

### P1 — execução e revisão de ports

- [ ] Documentar que a assinatura autentica o publicador, sem garantir que o
      programa seja benigno.
- [ ] Criar verificações automáticas para launchers e arquivos executáveis.
- [ ] Registrar procedência, licença e revisão editorial de cada pacote.
- [ ] Avaliar isolamento possível para ports no DarkOS.

Critério de conclusão: cada pacote publicado possui origem, licença, resultado
das verificações e decisão de revisão rastreáveis.

### P2 — manutenção do cliente

- [x] Implementar atualização de ports já instalados.
- [x] Mostrar versão instalada e versão disponível separadamente.
- [ ] Melhorar logs exportáveis para suporte.
- [ ] Testar restauração da sessão aria2 e política de bateria no hardware.
- [ ] Criar testes de interface para todos os fluxos do controle.

## Planejamento reservado do KMP Publisher

Nenhuma implementação começa antes da revisão das lacunas P0 do cliente. O
planejamento pode definir:

- leitura e preenchimento de metadados do `port.json`;
- seleção e inspeção do ZIP;
- validação de caminhos, licença e permissão de redistribuição;
- cálculo de hashes e geração do torrent com web seeds;
- teste de instalação em staging;
- geração de uma proposta compatível com o JSON Schema;
- criação de pull request para revisão editorial;
- apresentação clara dos erros ao desenvolvedor.

O Publisher **não recebe a chave privada oficial** e não publica diretamente o
catálogo. A assinatura permanece uma etapa editorial após revisão.

Fluxo planejado:

```text
Desenvolvedor -> KMP Publisher -> validação -> pull request
              -> revisão editorial -> assinatura -> KMP Catalog -> KMP Client
```

## Regra para novas tarefas

Até que as lacunas P0 sejam encerradas, mudanças no KMP Publisher devem se
limitar a requisitos, fluxos, ameaças, formatos e critérios de aceitação.
Implementações devem priorizar o KMP Client.
