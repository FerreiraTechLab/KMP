#!/usr/bin/env python3
"""Small HTTP BitTorrent tracker for KMP's LAN integration test."""

import argparse
import ipaddress
import struct
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import unquote_to_bytes, urlsplit


LOCK = threading.Lock()
SWARMS = {}
PEER_TTL = 120


def bencode(value):
    if isinstance(value, int):
        return b"i" + str(value).encode() + b"e"
    if isinstance(value, bytes):
        return str(len(value)).encode() + b":" + value
    if isinstance(value, dict):
        return b"d" + b"".join(
            bencode(key) + bencode(value[key]) for key in sorted(value)
        ) + b"e"
    raise TypeError(type(value))


def query_bytes(query):
    result = {}
    for field in query.split("&"):
        key, separator, value = field.partition("=")
        if separator:
            result[unquote_to_bytes(key)] = unquote_to_bytes(value.replace("+", " "))
    return result


def announce(client_ip, query, now=None):
    now = time.monotonic() if now is None else now
    fields = query_bytes(query)
    info_hash = fields.get(b"info_hash", b"")
    try:
        port = int(fields.get(b"port", b"0"))
        address = ipaddress.ip_address(client_ip)
    except (ValueError, TypeError):
        return {b"failure reason": b"invalid peer address"}
    if len(info_hash) != 20 or address.version != 4 or not 1 <= port <= 65535:
        return {b"failure reason": b"invalid announce"}

    peer = (client_ip, port)
    with LOCK:
        swarm = SWARMS.setdefault(info_hash, {})
        for candidate, seen in list(swarm.items()):
            if now - seen > PEER_TTL:
                del swarm[candidate]
        if fields.get(b"event") == b"stopped":
            swarm.pop(peer, None)
        else:
            swarm[peer] = now
        peers = b"".join(
            ipaddress.ip_address(ip).packed + struct.pack("!H", peer_port)
            for (ip, peer_port) in swarm if (ip, peer_port) != peer
        )
    return {b"complete": 1, b"incomplete": 1, b"interval": 5, b"peers": peers}


class TrackerHandler(BaseHTTPRequestHandler):
    def do_GET(self):
        request = urlsplit(self.path)
        if request.path != "/announce":
            self.send_error(404)
            return
        payload = bencode(announce(self.client_address[0], request.query))
        self.send_response(200)
        self.send_header("Content-Type", "text/plain")
        self.send_header("Content-Length", str(len(payload)))
        self.end_headers()
        self.wfile.write(payload)

    def log_message(self, message, *args):
        print("%s - %s" % (self.client_address[0], message % args), flush=True)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--bind", default="0.0.0.0")
    parser.add_argument("--port", type=int, default=6969)
    args = parser.parse_args()
    server = ThreadingHTTPServer((args.bind, args.port), TrackerHandler)
    print("KMP tracker listening on http://%s:%d/announce" % (args.bind, args.port), flush=True)
    server.serve_forever()


if __name__ == "__main__":
    main()
