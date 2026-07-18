#!/usr/bin/env python3
"""Inspect unconnected UDP source ports owned by an nginx worker process."""

import argparse
import os
import re
from pathlib import Path


SOCKET_TARGET = re.compile(r"socket:\[(\d+)\]")


def socket_inodes(pid: int) -> set[str]:
    inodes: set[str] = set()
    for fd in Path(f"/proc/{pid}/fd").iterdir():
        try:
            target = os.readlink(fd)
        except FileNotFoundError:
            continue
        match = SOCKET_TARGET.fullmatch(target)
        if match:
            inodes.add(match.group(1))
    return inodes


def udp_ports(pid: int, inodes: set[str]) -> set[int]:
    ports: set[int] = set()
    for table_name in ("udp", "udp6"):
        table = Path(f"/proc/{pid}/net/{table_name}")
        try:
            lines = table.read_text(encoding="ascii").splitlines()[1:]
        except FileNotFoundError:
            continue
        for line in lines:
            fields = line.split()
            if len(fields) < 10 or fields[9] not in inodes:
                continue
            _remote_address, remote_port_hex = fields[2].rsplit(":", 1)
            if int(remote_port_hex, 16) != 0:
                # nginx's resolver socket is connected to the DNS fixture. The
                # RateLimitly socket is intentionally unconnected.
                continue
            _address, port_hex = fields[1].rsplit(":", 1)
            port = int(port_hex, 16)
            if port != 0:
                ports.add(port)
    return ports


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("pid", type=int)
    parser.add_argument(
        "--count",
        action="store_true",
        help="print the number of module UDP sockets instead of requiring one",
    )
    args = parser.parse_args()

    ports = udp_ports(args.pid, socket_inodes(args.pid))
    if args.count:
        print(len(ports))
        return 0
    if len(ports) != 1:
        formatted = ", ".join(str(port) for port in sorted(ports)) or "none"
        parser.error(f"expected one worker UDP socket, found: {formatted}")
    print(next(iter(ports)))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
