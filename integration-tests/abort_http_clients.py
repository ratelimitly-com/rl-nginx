#!/usr/bin/env python3
"""Send complete HTTP requests, then reset every connection before a response."""

import argparse
import socket
import struct
import time


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--host", required=True)
    parser.add_argument("--port", required=True, type=int)
    parser.add_argument("--requests", required=True, type=int)
    parser.add_argument("--settle-ms", default=50, type=int)
    args = parser.parse_args()

    sockets: list[socket.socket] = []
    try:
        for request_id in range(args.requests):
            sock = socket.create_connection((args.host, args.port), timeout=2)
            payload = (
                f"GET /limited?abort={request_id} HTTP/1.1\r\n"
                f"Host: {args.host}\r\n"
                "Connection: close\r\n"
                "\r\n"
            ).encode("ascii")
            sock.sendall(payload)
            sockets.append(sock)

        time.sleep(args.settle_ms / 1000)
        reset_linger = struct.pack("ii", 1, 0)
        for sock in sockets:
            sock.setsockopt(socket.SOL_SOCKET, socket.SO_LINGER, reset_linger)
            sock.close()
        sockets.clear()
    finally:
        for sock in sockets:
            sock.close()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
