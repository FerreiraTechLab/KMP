#!/usr/bin/env python3
"""Maintain an automatic TCP/UDP BitTorrent port mapping for KMP."""

from __future__ import annotations

import argparse
import ipaddress
import json
import os
from pathlib import Path
import signal
import socket
import struct
import tempfile
import time
from urllib.parse import urljoin, urlsplit
from urllib.request import Request, urlopen
import xml.etree.ElementTree as ET


SSDP_ADDRESS = ("239.255.255.250", 1900)
SERVICES = ("WANIPConnection", "WANPPPConnection")


def atomic_json(path: Path, document: dict) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    descriptor, name = tempfile.mkstemp(prefix=path.name + ".", dir=path.parent)
    try:
        with os.fdopen(descriptor, "w", encoding="utf-8") as handle:
            json.dump(document, handle, ensure_ascii=False, sort_keys=True)
            handle.write("\n")
            handle.flush()
            os.fsync(handle.fileno())
        os.chmod(name, 0o600)
        os.replace(name, path)
    except BaseException:
        try:
            os.unlink(name)
        except FileNotFoundError:
            pass
        raise


def address_scope(address: str | None) -> str:
    if not address:
        return "unknown"
    try:
        value = ipaddress.ip_address(address)
    except ValueError:
        return "unknown"
    if isinstance(value, ipaddress.IPv4Address) and value in ipaddress.ip_network("100.64.0.0/10"):
        return "cgnat"
    if value.is_private or value.is_loopback or value.is_link_local or value.is_reserved:
        return "private"
    return "public"


def local_ipv4(target: str) -> str:
    with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as probe:
        probe.connect((target, 9))
        return probe.getsockname()[0]


def default_gateway() -> str | None:
    try:
        for line in Path("/proc/net/route").read_text().splitlines()[1:]:
            fields = line.split()
            if len(fields) >= 4 and fields[1] == "00000000" and int(fields[3], 16) & 2:
                return socket.inet_ntoa(struct.pack("<L", int(fields[2], 16)))
    except (OSError, ValueError):
        pass
    return None


def ssdp_locations(timeout: float = 2.0) -> list[str]:
    message = ("M-SEARCH * HTTP/1.1\r\nHOST: 239.255.255.250:1900\r\n"
               'MAN: "ssdp:discover"\r\nMX: 2\r\n'
               "ST: urn:schemas-upnp-org:device:InternetGatewayDevice:1\r\n\r\n")
    locations = []
    with socket.socket(socket.AF_INET, socket.SOCK_DGRAM, socket.IPPROTO_UDP) as client:
        client.settimeout(timeout)
        client.sendto(message.encode("ascii"), SSDP_ADDRESS)
        deadline = time.monotonic() + timeout
        while time.monotonic() < deadline:
            try:
                data, _address = client.recvfrom(65535)
            except socket.timeout:
                break
            headers = {}
            for line in data.decode("iso-8859-1", "replace").split("\r\n")[1:]:
                if ":" in line:
                    key, value = line.split(":", 1)
                    headers[key.strip().lower()] = value.strip()
            location = headers.get("location")
            if location and location not in locations:
                locations.append(location)
    return locations


def upnp_service(location: str) -> tuple[str, str]:
    parsed = urlsplit(location)
    if parsed.scheme != "http" or not parsed.hostname or address_scope(parsed.hostname) != "private":
        raise ValueError("descrição UPnP insegura")
    with urlopen(Request(location, headers={"User-Agent": "KMP/0.2 UPnP"}), timeout=3) as response:
        document = ET.fromstring(response.read(1024 * 1024))
    for service in document.iter():
        if not service.tag.endswith("service"):
            continue
        values = {child.tag.rsplit("}", 1)[-1]: child.text or "" for child in service}
        service_type = values.get("serviceType", "")
        if any(name in service_type for name in SERVICES) and values.get("controlURL"):
            return urljoin(location, values["controlURL"]), service_type
    raise ValueError("serviço de gateway UPnP ausente")


def soap(control_url: str, service_type: str, action: str,
         arguments: dict[str, object]) -> bytes:
    values = "".join(f"<{key}>{value}</{key}>" for key, value in arguments.items())
    body = (f'<?xml version="1.0"?><s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/" '
            f's:encodingStyle="http://schemas.xmlsoap.org/soap/encoding/"><s:Body>'
            f'<u:{action} xmlns:u="{service_type}">{values}</u:{action}>'
            f'</s:Body></s:Envelope>').encode()
    request = Request(control_url, data=body, method="POST", headers={
        "Content-Type": 'text/xml; charset="utf-8"',
        "SOAPAction": f'"{service_type}#{action}"', "User-Agent": "KMP/0.2 UPnP"})
    with urlopen(request, timeout=4) as response:
        return response.read(256 * 1024)


class UpnpMapping:
    method = "upnp"

    def __init__(self, control_url: str, service_type: str, port: int, local_ip: str):
        self.control_url, self.service_type = control_url, service_type
        self.port, self.local_ip = port, local_ip

    @classmethod
    def create(cls, port: int):
        errors = []
        for location in ssdp_locations():
            try:
                control, service = upnp_service(location)
                mapping = cls(control, service, port, local_ipv4(urlsplit(control).hostname))
                mapping.renew()
                return mapping
            except Exception as exc:
                errors.append(str(exc))
        raise RuntimeError("UPnP indisponível" + (": " + "; ".join(errors) if errors else ""))

    def external_address(self) -> str | None:
        try:
            root = ET.fromstring(soap(self.control_url, self.service_type,
                                      "GetExternalIPAddress", {}))
            return next((node.text for node in root.iter()
                         if node.tag.endswith("NewExternalIPAddress")), None)
        except Exception:
            return None

    def renew(self) -> None:
        for protocol in ("TCP", "UDP"):
            arguments = {"NewRemoteHost": "", "NewExternalPort": self.port,
                         "NewProtocol": protocol, "NewInternalPort": self.port,
                         "NewInternalClient": self.local_ip, "NewEnabled": 1,
                         "NewPortMappingDescription": "KMP BitTorrent",
                         "NewLeaseDuration": 3600}
            try:
                soap(self.control_url, self.service_type, "AddPortMapping", arguments)
            except Exception:
                arguments["NewLeaseDuration"] = 0
                soap(self.control_url, self.service_type, "AddPortMapping", arguments)

    def close(self) -> None:
        for protocol in ("TCP", "UDP"):
            try:
                soap(self.control_url, self.service_type, "DeletePortMapping",
                     {"NewRemoteHost": "", "NewExternalPort": self.port,
                      "NewProtocol": protocol})
            except Exception:
                pass


def natpmp_request(gateway: str, payload: bytes, opcode: int, timeout: float = 1.0) -> bytes:
    with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as client:
        client.settimeout(timeout)
        for _ in range(3):
            client.sendto(payload, (gateway, 5351))
            try:
                response, address = client.recvfrom(64)
                if address[0] == gateway and len(response) >= 8 and response[0] == 0 and \
                        response[1] == opcode + 128 and struct.unpack("!H", response[2:4])[0] == 0:
                    return response
            except socket.timeout:
                continue
    raise RuntimeError("NAT-PMP indisponível")


class NatPmpMapping:
    method = "nat-pmp"

    def __init__(self, gateway: str, port: int):
        self.gateway, self.port = gateway, port

    @classmethod
    def create(cls, port: int):
        gateway = default_gateway()
        if not gateway:
            raise RuntimeError("gateway padrão não encontrado")
        mapping = cls(gateway, port)
        mapping.renew()
        return mapping

    def external_address(self) -> str | None:
        try:
            response = natpmp_request(self.gateway, b"\0\0", 0)
            return socket.inet_ntoa(response[8:12]) if len(response) >= 12 else None
        except Exception:
            return None

    def _map(self, opcode: int, lifetime: int) -> None:
        request = struct.pack("!BBHHHI", 0, opcode, 0, self.port, self.port, lifetime)
        response = natpmp_request(self.gateway, request, opcode)
        if len(response) < 16 or struct.unpack("!H", response[10:12])[0] != self.port:
            raise RuntimeError("NAT-PMP atribuiu uma porta externa diferente")

    def renew(self) -> None:
        self._map(2, 3600)
        self._map(1, 3600)

    def close(self) -> None:
        for opcode in (2, 1):
            try:
                self._map(opcode, 0)
            except Exception:
                pass


def acquire_mapping(port: int):
    errors = []
    for implementation in (UpnpMapping, NatPmpMapping):
        try:
            return implementation.create(port), errors
        except Exception as exc:
            errors.append(f"{implementation.method}: {exc}")
    return None, errors


def run(port: int, state_path: Path, renew_seconds: int) -> int:
    stopping = False

    def stop(_signal, _frame):
        nonlocal stopping
        stopping = True

    signal.signal(signal.SIGTERM, stop)
    signal.signal(signal.SIGINT, stop)
    mapping = None
    while not stopping:
        try:
            if mapping is None:
                mapping, errors = acquire_mapping(port)
                if mapping is None:
                    atomic_json(state_path, {"active": False, "method": None, "port": port,
                                              "errors": errors, "updatedAt": int(time.time())})
                else:
                    external = mapping.external_address()
                    scope = address_scope(external)
                    atomic_json(state_path, {"active": True, "method": mapping.method,
                                              "port": port, "externalAddress": external,
                                              "addressScope": scope,
                                              "internetReachable": scope == "public",
                                              "updatedAt": int(time.time())})
            else:
                mapping.renew()
            deadline = time.monotonic() + renew_seconds
            while not stopping and time.monotonic() < deadline:
                time.sleep(min(1, deadline - time.monotonic()))
        except Exception as exc:
            atomic_json(state_path, {"active": False, "method": None, "port": port,
                                      "errors": [str(exc)], "updatedAt": int(time.time())})
            if mapping:
                mapping.close()
                mapping = None
            time.sleep(min(30, renew_seconds))
    if mapping:
        mapping.close()
    atomic_json(state_path, {"active": False, "method": None, "port": port,
                              "stopped": True, "updatedAt": int(time.time())})
    return 0


def set_process_name(name: str) -> bool:
    """Troca o nome do processo (o que o ps e o killall veem).

    Ao sair de qualquer port, o PortMaster roda `killall python3`. Sem isto, fechar o KMP
    ou um jogo encerrava este processo, que deve viver junto com o kmp-torrentd: o
    daemon.sh o controla pelo PID.
    """
    try:
        import ctypes
        libc = ctypes.CDLL(None, use_errno=True)
        return libc.prctl(15, ctypes.c_char_p(name.encode()[:15]), 0, 0, 0) == 0  # PR_SET_NAME
    except (OSError, AttributeError):
        return False


def main() -> int:
    set_process_name("kmp-portmap")
    parser = argparse.ArgumentParser()
    parser.add_argument("--port", required=True, type=int)
    parser.add_argument("--state", required=True, type=Path)
    parser.add_argument("--renew-seconds", type=int, default=1200)
    args = parser.parse_args()
    if not 1024 <= args.port <= 65535 or args.renew_seconds < 30:
        parser.error("porta ou intervalo inválido")
    return run(args.port, args.state, args.renew_seconds)


if __name__ == "__main__":
    raise SystemExit(main())
