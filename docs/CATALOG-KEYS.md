# Operação das chaves do catálogo

## Papéis

- A chave privada editorial assina o snapshot e o `head.json`.
- O cliente contém somente a chave pública inicial.
- Na primeira execução, o cliente copia essa chave para
  `conf/catalog/trusted-key.pem`. Depois disso, usa sempre a cópia persistente.

## Armazenamento e backup

A chave privada oficial não deve ficar no repositório, no GitHub Pages, no nó
de seed nem no console. Mantenha o arquivo cifrado em uma estação editorial e
duas cópias offline em mídias distintas. Guarde a senha separadamente. Teste a
restauração das cópias e compare a chave pública restaurada com o fingerprint
publicado antes de assinar qualquer release.

## Rotação planejada

1. Gere o novo par Ed25519 e faça os backups offline.
2. Publique uma última sequência assinada pela chave vigente usando
   `catalog-release.py --next-public-key nova-chave.pub`.
3. O cliente verifica o head e o catálogo com a chave vigente. Somente depois
   da ativação completa ele grava a nova chave em `trusted-key.pem`.
4. Assine todas as sequências seguintes com a nova chave privada.
5. Mantenha o head de transição em todos os mirrors por tempo suficiente para
   os consoles que ficam desligados.

O campo `nextKey` contém a chave pública, seu SHA-256 e a sequência que autoriza
a troca. Ele faz parte do head assinado e não pode ser alterado por um mirror.

## Perda ou comprometimento

Se a chave privada for perdida antes de uma rotação autorizada, nenhuma nova
sequência deve ser assinada. O último snapshot verificado continua ativo nos
consoles. A recuperação exige uma versão de manutenção do KMP distribuída pelo
canal oficial do cliente, com uma nova chave inicial e uma migração explícita
do arquivo persistente.

Se houver suspeita de comprometimento, interrompa a publicação e preserve os
heads, snapshots e logs para auditoria. Se ainda houver controle seguro da
chave, publique imediatamente uma rotação autorizada. Caso contrário, use o
mesmo processo de versão de manutenção. Uma chave de rede não pode revogar a si
mesma com segurança depois que o segredo foi roubado.

Nunca apague `trusted-key.pem` como procedimento comum de suporte: isso reduz a
confiança do console à chave contida no pacote instalado.

## Relógio do console

Após cada ativação, o cliente salva `lastTrustedTime` em `state.json`. Se o
relógio voltar mais de dez minutos, a sincronização informa que o relógio está
inválido e mantém o snapshot ativo. Um head expirado continua sendo rejeitado;
ajustar o relógio não desativa a verificação de validade.
