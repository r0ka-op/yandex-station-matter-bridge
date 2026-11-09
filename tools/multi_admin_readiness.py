#!/usr/bin/env python3
"""Read-only Multi-Admin readiness checks.

This program has no invoke/write code path. It reads only /devices and Matter
attributes, or checks local network/server prerequisites.
"""
from __future__ import annotations

import argparse
import ipaddress
import json
import socket
import sys
import urllib.error
import urllib.parse
import urllib.request
from pathlib import Path

ATTRS = {
    "administrator_commissioning": (0x003C, (0xFFF8, 0xFFF9, 0xFFFB, 0xFFFC, 0xFFFD, 0, 1, 2)),
    "operational_credentials": (0x003E, (0xFFF8, 0xFFF9, 0xFFFB, 0xFFFC, 0xFFFD, 2, 3, 5)),
}


def _loopback_url(value: str) -> str:
    parsed = urllib.parse.urlsplit(value)
    if parsed.scheme != "http" or not parsed.hostname:
        raise argparse.ArgumentTypeError("base URL must be HTTP")
    try:
        loopback = ipaddress.ip_address(parsed.hostname).is_loopback
    except ValueError:
        loopback = parsed.hostname == "localhost"
    if not loopback:
        raise argparse.ArgumentTypeError("maind is unauthenticated; use an SSH tunnel and loopback URL")
    return value.rstrip("/")


def _request(base: str, method: str, path: str, payload=None):
    data = None if payload is None else json.dumps(payload, separators=(",", ":")).encode()
    req = urllib.request.Request(base + path, data=data, method=method)
    if data is not None:
        req.add_header("Content-Type", "application/json")
    with urllib.request.urlopen(req, timeout=5) as response:
        return json.load(response)


def run_maind(args) -> dict:
    result = {"mode": "read-only", "devices": _request(args.base_url, "GET", "/devices"), "reads": []}
    for group, (cluster, attrs) in ATTRS.items():
        for attr in attrs:
            payload = {"nodeId": args.node_id, "endpointId": 0, "clusterId": cluster, "attributeId": attr}
            try:
                body = _request(args.base_url, "POST", "/interaction/readAttribute", payload)
                result["reads"].append({"group": group, "request": payload, "response": body})
            except urllib.error.HTTPError as exc:
                result["reads"].append({"group": group, "request": payload, "http_status": exc.code,
                                        "response": exc.read().decode(errors="replace")})
    return result


def run_network(args) -> dict:
    ipv6 = []
    try:
        for item in socket.getaddrinfo(socket.gethostname(), None, socket.AF_INET6):
            address = item[4][0]
            if address not in ipv6:
                ipv6.append(address)
    except socket.gaierror:
        pass
    server = {"host": args.server_host, "port": args.server_port, "tcp_reachable": False}
    try:
        with socket.create_connection((args.server_host, args.server_port), timeout=3):
            server["tcp_reachable"] = True
    except OSError as exc:
        server["error"] = str(exc)
    return {"mode": "read-only", "ipv6_addresses": ipv6, "has_non_loopback_ipv6": any(
        not ipaddress.ip_address(x.split("%")[0]).is_loopback for x in ipv6), "matter_server": server,
        "manual_checks": ["mDNS _matterc._udp during open window", "UDP/5540 firewall", "same VLAN/no client isolation"]}


def main(argv=None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    sub = parser.add_subparsers(dest="command", required=True)
    maind = sub.add_parser("maind", help="read Administrator Commissioning and Operational Credentials")
    maind.add_argument("--base-url", type=_loopback_url, required=True)
    maind.add_argument("--node-id", type=lambda x: int(x, 0), required=True)
    maind.add_argument("--output", type=Path)
    network = sub.add_parser("network", help="check local IPv6 and Matter Server TCP readiness")
    network.add_argument("--server-host", default="127.0.0.1")
    network.add_argument("--server-port", type=int, default=5580)
    network.add_argument("--output", type=Path)
    args = parser.parse_args(argv)
    result = run_maind(args) if args.command == "maind" else run_network(args)
    text = json.dumps(result, indent=2, ensure_ascii=False)
    if args.output:
        args.output.parent.mkdir(parents=True, exist_ok=True)
        args.output.write_text(text + "\n", encoding="utf-8")
    print(text)
    return 0


if __name__ == "__main__":
    sys.exit(main())
