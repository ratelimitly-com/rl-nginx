#!/usr/bin/env python3
import argparse
import ipaddress
import signal
import socket
import struct
import sys


TYPE_A = 1
TYPE_AAAA = 28
TYPE_SRV = 33
TYPE_ANY = 255
CLASS_IN = 1


def encode_name(name: str) -> bytes:
    labels = [label for label in name.rstrip(".").split(".") if label]
    encoded = bytearray()
    for label in labels:
        raw = label.encode("ascii")
        encoded.append(len(raw))
        encoded.extend(raw)
    encoded.append(0)
    return bytes(encoded)


def decode_name(message: bytes, offset: int) -> tuple[str, int]:
    labels: list[str] = []
    jumped = False
    next_offset = offset
    seen_offsets: set[int] = set()

    while True:
        if offset >= len(message):
            raise ValueError("name exceeds message length")
        if offset in seen_offsets:
            raise ValueError("name compression loop")
        seen_offsets.add(offset)

        length = message[offset]
        if length == 0:
            offset += 1
            if not jumped:
                next_offset = offset
            break
        if length & 0xC0 == 0xC0:
            if offset + 1 >= len(message):
                raise ValueError("truncated compression pointer")
            pointer = ((length & 0x3F) << 8) | message[offset + 1]
            if not jumped:
                next_offset = offset + 2
            offset = pointer
            jumped = True
            continue
        offset += 1
        end = offset + length
        if end > len(message):
            raise ValueError("truncated label")
        labels.append(message[offset:end].decode("ascii"))
        offset = end

    return ".".join(labels).lower(), next_offset


def build_rr(name_ptr: bytes, rr_type: int, rr_class: int, ttl: int, rdata: bytes) -> bytes:
    return (
        name_ptr
        + struct.pack("!HHI", rr_type, rr_class, ttl)
        + struct.pack("!H", len(rdata))
        + rdata
    )


class DnsServer:
    def __init__(self, host: str, port: int, domain: str, records: list[str]) -> None:
        self.host = host
        self.port = port
        self.domain = domain.rstrip(".").lower()
        self.srv_owner = f"_ratelimitly._udp.{self.domain}"
        self.records: list[tuple[int, int]] = []
        self.srv_targets: set[str] = set()
        for record in records:
            server_id, port_str = record.split(":", 1)
            parsed_server_id = int(server_id)
            self.records.append((parsed_server_id, int(port_str)))
            self.srv_targets.add(f"s-{parsed_server_id}.localhost")
        self.running = True

    def stop(self, *_args) -> None:
        self.running = False

    def name_exists(self, qname: str) -> bool:
        qname = qname.rstrip(".").lower()
        return qname == self.srv_owner or qname in self.srv_targets

    def answers_for(self, qname: str, qtype: int) -> list[bytes]:
        qname = qname.rstrip(".").lower()
        answers: list[bytes] = []
        name_ptr = b"\xC0\x0C"

        if qname == self.srv_owner and qtype in (TYPE_SRV, TYPE_ANY):
            for server_id, port in self.records:
                target = f"s-{server_id}.localhost"
                rdata = struct.pack("!HHH", 10, 50, port) + encode_name(target)
                answers.append(build_rr(name_ptr, TYPE_SRV, CLASS_IN, 30, rdata))
            return answers

        if qname not in self.srv_targets:
            return answers

        if qtype in (TYPE_A, TYPE_ANY):
            answers.append(
                build_rr(
                    name_ptr,
                    TYPE_A,
                    CLASS_IN,
                    30,
                    ipaddress.IPv4Address("127.0.0.1").packed,
                )
            )
        if qtype in (TYPE_AAAA, TYPE_ANY):
            answers.append(
                build_rr(
                    name_ptr,
                    TYPE_AAAA,
                    CLASS_IN,
                    30,
                    ipaddress.IPv6Address("::1").packed,
                )
            )

        return answers

    def serve(self) -> int:
        family = socket.AF_INET6 if ":" in self.host else socket.AF_INET
        sock = socket.socket(family, socket.SOCK_DGRAM)
        try:
            if family == socket.AF_INET6:
                sock.setsockopt(socket.IPPROTO_IPV6, socket.IPV6_V6ONLY, 0)
            sock.bind((self.host, self.port))
            sock.settimeout(0.5)
            print(
                f"local DNS server listening on {self.host}:{self.port} for {self.srv_owner}",
                flush=True,
            )
            while self.running:
                try:
                    payload, addr = sock.recvfrom(2048)
                except socket.timeout:
                    continue
                except OSError:
                    if self.running:
                        raise
                    break

                response = self.handle_query(payload)
                if response is not None:
                    sock.sendto(response, addr)
        finally:
            sock.close()
        return 0

    def handle_query(self, message: bytes) -> bytes | None:
        if len(message) < 12:
            return None

        transaction_id, flags, qdcount, _ancount, _nscount, _arcount = struct.unpack(
            "!HHHHHH", message[:12]
        )
        if qdcount == 0:
            return None

        try:
            qname, offset = decode_name(message, 12)
        except ValueError:
            return None

        if offset + 4 > len(message):
            return None

        qtype, qclass = struct.unpack("!HH", message[offset : offset + 4])
        question = message[12 : offset + 4]

        if qclass != CLASS_IN:
            rcode = 4
            answers = []
        else:
            answers = self.answers_for(qname, qtype)
            rcode = 0 if answers or self.name_exists(qname) else 3

        response_flags = 0x8000 | 0x0400 | (flags & 0x0100) | rcode
        header = struct.pack(
            "!HHHHHH",
            transaction_id,
            response_flags,
            1,
            len(answers),
            0,
            0,
        )
        return header + question + b"".join(answers)


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--listen-host", required=True)
    parser.add_argument("--port", required=True, type=int)
    parser.add_argument("--domain", required=True)
    parser.add_argument("--record", action="append", default=[])
    args = parser.parse_args()

    server = DnsServer(args.listen_host, args.port, args.domain, args.record)
    signal.signal(signal.SIGTERM, server.stop)
    signal.signal(signal.SIGINT, server.stop)
    return server.serve()


if __name__ == "__main__":
    sys.exit(main())
