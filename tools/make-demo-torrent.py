#!/usr/bin/env python3
"""Create a tiny redistributable single-file torrent for KMP integration tests."""

import argparse
import hashlib
import json
from pathlib import Path
from urllib.parse import quote
import zipfile


def bencode(value):
    if isinstance(value, int):
        return b"i" + str(value).encode() + b"e"
    if isinstance(value, (bytes, str)):
        data = value.encode() if isinstance(value, str) else value
        return str(len(data)).encode() + b":" + data
    if isinstance(value, list):
        return b"l" + b"".join(bencode(item) for item in value) + b"e"
    if isinstance(value, dict):
        return b"d" + b"".join(
            bencode(key) + bencode(value[key]) for key in sorted(value)
        ) + b"e"
    raise TypeError(type(value))


def build(output, tracker=None):
    output.mkdir(parents=True, exist_ok=True)
    package = output / "kmp-demo-v1.zip"
    with zipfile.ZipFile(package, "w", compression=zipfile.ZIP_DEFLATED) as archive:
        archive.writestr("kmp-demo.sh", "#!/bin/sh\nprintf 'KMP demo instalado\\n'\n")
        archive.writestr("kmp-demo/README.txt", "Pacote de demonstração para testar o KDownloader.\n")
        archive.writestr("kmp-demo/LICENSE.txt", "Este pacote de demonstração é dedicado ao domínio público (CC0-1.0).\n")
    payload = package.read_bytes()
    piece_length = 256 * 1024
    info = {
        "length": len(payload),
        "name": package.name,
        "piece length": piece_length,
        "pieces": b"".join(hashlib.sha1(payload[index:index + piece_length]).digest()
                         for index in range(0, len(payload), piece_length)),
    }
    info_hash = hashlib.sha1(bencode(info)).hexdigest()
    torrent = {"info": info}
    if tracker:
        torrent["announce"] = tracker
    else:
        torrent["nodes"] = []
    (output / "kmp-demo.torrent").write_bytes(bencode(torrent))
    magnet = "magnet:?xt=urn:btih:" + info_hash + "&dn=" + quote(package.name)
    if tracker:
        magnet += "&tr=" + quote(tracker, safe="")
    catalog = {
        "schemaVersion": 1,
        "items": [{
            "id": "kmp-demo-v1", "name": "KMP Demo", "version": "1.0",
            "description": "Pacote pequeno para testar o fluxo BitTorrent",
            "sizeBytes": len(payload), "license": "CC0-1.0",
            "infoHash": info_hash, "magnet": magnet,
            "packageFile": package.name,
            "install": {"portId": "kmp-demo", "paths": ["kmp-demo.sh", "kmp-demo/"]},
        }],
    }
    (output / "catalog-v1.json").write_text(
        json.dumps(catalog, ensure_ascii=False, indent=2) + "\n", encoding="utf-8"
    )
    print("InfoHash:", info_hash)
    print("Arquivos:", package, output / "kmp-demo.torrent", output / "catalog-v1.json")


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("output", type=Path)
    parser.add_argument("--tracker", help="Optional tracker announce URL")
    args = parser.parse_args()
    build(args.output, args.tracker)


if __name__ == "__main__":
    main()
