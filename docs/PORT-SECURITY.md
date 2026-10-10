# Política de segurança e revisão de ports

O auditor reduz erros de empacotamento e destaca comportamentos que precisam de
revisão. Ele não prova que um programa é benigno e não substitui leitura de
código, procedência, licença ou execução em hardware de teste.

## Uso

```sh
python3 tools/audit-package.py submission-v1.json \
  --variant aarch64-portmaster \
  --output audit-report.json
```

O comando retorna código 1 quando encontra erro. Alertas mantêm código 0 para
permitir análise editorial; `--fail-on-warning` faz qualquer alerta falhar no
CI. O relatório segue `schemas/audit-report-v1.schema.json`.

## Reprovação automática

- tamanho ou SHA-256 diferente da proposta;
- ZIP inválido, criptografado, com CRC incorreto ou caminhos duplicados;
- caminho absoluto, travessia com `..`, barra invertida ou raiz não declarada;
- link simbólico, arquivo especial, `setuid` ou `setgid`;
- executável ELF de arquitetura diferente da variante;
- script sem shebang;
- escrita ou alteração explícita em `/etc`, `/usr` ou `/boot`;
- escrita direta em dispositivos de `/dev`;
- tentativa literal de `rm -rf /`;
- ausência de launcher `.sh` na raiz;
- limites por entrada, quantidade, expansão ou taxa extrema de compressão
  excedidos.

## Alertas para revisão humana

- download realizado pelo launcher;
- download conectado diretamente a `sh` ou `bash`;
- uso de gerenciador de pacotes, `sudo`, `su`, serviços ou montagens;
- `chmod 777`, `eval` ou interpretador incomum;
- licença não incluída dentro do ZIP;
- taxa de compressão incomum.

Um alerta pode ser legítimo em um port específico. A decisão e sua justificativa
devem ser registradas no processo editorial. O relatório nunca marca esses
casos silenciosamente como seguros.

## Efeito no Client

O Client não bloqueia uma instalação por alerta do auditor nem pela ausência de
isolamento. Ele mostra o estado da revisão e permite que o usuário prossiga. Um
desenvolvedor pode, por exemplo, ter esquecido de incluir o arquivo de licença
no ZIP mesmo quando a licença e sua evidência estão declaradas na proposta.

Somente uma reprovação editorial, uma revogação assinada ou uma falha objetiva
verificada pelo próprio Client, como hash incorreto, pacote incompatível ou
estrutura insegura, impede a instalação.

## Isolamento de execução

DarkOS e Aurknix precisam expor ao port recursos como GPU, áudio, controles e
diretórios de saves. Um isolamento obrigatório pode impedir ports legítimos de
funcionar e não será requisito de instalação.

Caso um mecanismo compatível seja desenvolvido, ele deve ser opcional e
ativado por variante após teste no hardware. Executar sem isolamento pode ser
informado ao usuário, mas não altera a decisão editorial nem impede a
instalação.

## Etapas editoriais posteriores

1. Repetir o auditor em ambiente limpo.
2. Comparar o hash com a proposta.
3. Conferir upstream, licença e permissão de redistribuição.
4. Inspecionar manualmente todos os executáveis e alertas.
5. Executar em hardware compatível sem credenciais ou dados pessoais.
6. Registrar a decisão pública antes de assinar o catálogo.
