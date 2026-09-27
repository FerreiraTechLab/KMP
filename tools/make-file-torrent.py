#!/usr/bin/env python3
"""Create a deterministic v1 single-file torrent and print its magnet URI."""

import argparse
import hashlib
from pathlib import Path
from urllib.parse import quote


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


def build(source: Path, output: Path, trackers: list[str]) -> str:
    payload = source.read_bytes()
    if not payload:
        raise ValueError("arquivo vazio")
    piece_length = 256 * 1024
    info = {
        "length": len(payload),
        "name": source.name,
        "piece length": piece_length,
        "pieces": b"".join(hashlib.sha1(payload[offset:offset + piece_length]).digest()
                            for offset in range(0, len(payload), piece_length)),
    }
    torrent = {"info": info}
    if trackers:
        torrent["announce"] = trackers[0]
        torrent["announce-list"] = [[tracker] for tracker in trackers]
    else:
        torrent["nodes"] = []
    output.write_bytes(bencode(torrent))
    info_hash = hashlib.sha1(bencode(info)).hexdigest()
    magnet = "magnet:?xt=urn:btih:" + info_hash + "&dn=" + quote(source.name)
    for tracker in trackers:
        magnet += "&tr=" + quote(tracker, safe="")
    return magnet


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("source", type=Path)
    parser.add_argument("--output", required=True, type=Path)
    parser.add_argument("--tracker", action="append", default=[])
    args = parser.parse_args()
    try:
        magnet = build(args.source, args.output, args.tracker)
    except (OSError, ValueError) as exc:
        parser.error(str(exc))
    print(magnet)


if __name__ == "__main__":
    main()
