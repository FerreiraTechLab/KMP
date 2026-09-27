# Publicação do catálogo oficial

Os arquivos `catalog-XXXXXXXX.json` são os snapshots assinados. A sequência
sempre cresce e um snapshot publicado nunca deve ser alterado.

O torrent do snapshot deve incluir os dois web seeds oficiais:

```text
https://ferreiratechlab.github.io/KMP-catalog/snapshots/catalog-XXXXXXXX.json
https://raw.githubusercontent.com/FerreiraTechLab/KMP-catalog/main/docs/snapshots/catalog-XXXXXXXX.json
```

Assim, o primeiro download pode vir do GitHub e o aria2 mantém o torrent ativo
para servir o mesmo snapshot a outros consoles.
