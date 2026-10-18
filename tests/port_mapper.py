#!/usr/bin/env python3

import importlib.util
from pathlib import Path
import struct
import tempfile
import unittest
from unittest import mock

ROOT = Path(__file__).resolve().parents[1]
SPEC = importlib.util.spec_from_file_location("port_mapper", ROOT / "KMP" / "port_mapper.py")
MODULE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(MODULE)


class PortMapperTests(unittest.TestCase):
    def test_address_scope(self):
        self.assertEqual(MODULE.address_scope("100.70.1.2"), "cgnat")
        self.assertEqual(MODULE.address_scope("192.168.1.2"), "private")
        self.assertEqual(MODULE.address_scope("8.8.8.8"), "public")
        self.assertEqual(MODULE.address_scope("2804:14d::1"), "public")

    def test_default_gateway_uses_linux_little_endian_route(self):
        route = "Iface Destination Gateway Flags\neth0 00000000 0100A8C0 0003\n"
        with mock.patch.object(MODULE.Path, "read_text", return_value=route):
            self.assertEqual(MODULE.default_gateway(), "192.168.0.1")

    def test_natpmp_maps_tcp_and_udp(self):
        calls = []
        def request(_gateway, payload, opcode, timeout=1):
            calls.append((opcode, struct.unpack("!I", payload[8:12])[0]))
            response = bytearray(16)
            response[10:12] = (6881).to_bytes(2, "big")
            return bytes(response)
        mapping = MODULE.NatPmpMapping("192.168.0.1", 6881)
        with mock.patch.object(MODULE, "natpmp_request", side_effect=request):
            mapping.renew()
            mapping.close()
        self.assertEqual(calls, [(2, 3600), (1, 3600), (2, 0), (1, 0)])


if __name__ == "__main__":
    unittest.main()
