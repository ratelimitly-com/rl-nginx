#!/usr/bin/env python3
import struct
import sys
import unittest

sys.dont_write_bytecode = True

from local_dns_server import (
    CLASS_IN,
    TYPE_A,
    TYPE_AAAA,
    TYPE_ANY,
    TYPE_SRV,
    DnsServer,
    encode_name,
)


def build_query(name: str, qtype: int) -> bytes:
    header = struct.pack("!HHHHHH", 0x1234, 0x0100, 1, 0, 0, 0)
    question = encode_name(name) + struct.pack("!HH", qtype, CLASS_IN)
    return header + question


def response_counts(response: bytes) -> tuple[int, int]:
    _transaction_id, flags, _qdcount, answer_count, _nscount, _arcount = (
        struct.unpack("!HHHHHH", response[:12])
    )
    return flags & 0xF, answer_count


class DnsServerTargetTests(unittest.TestCase):
    def setUp(self) -> None:
        self.server = DnsServer(
            "127.0.0.1",
            15353,
            "rn-test.local",
            ["1:19080", "2:19081"],
        )

    def query_counts(self, name: str, qtype: int) -> tuple[int, int]:
        response = self.server.handle_query(build_query(name, qtype))
        self.assertIsNotNone(response)
        return response_counts(response)

    def test_srv_owner_advertises_every_configured_target(self) -> None:
        self.assertEqual(
            self.query_counts("_ratelimitly._udp.rn-test.local", TYPE_SRV),
            (0, 2),
        )

    def test_advertised_targets_have_address_records(self) -> None:
        for target in ("s-1.localhost", "s-2.localhost"):
            with self.subTest(target=target, qtype="A"):
                self.assertEqual(self.query_counts(target, TYPE_A), (0, 1))
            with self.subTest(target=target, qtype="AAAA"):
                self.assertEqual(self.query_counts(target, TYPE_AAAA), (0, 1))
            with self.subTest(target=target, qtype="ANY"):
                self.assertEqual(self.query_counts(target, TYPE_ANY), (0, 2))

    def test_unadvertised_localhost_names_are_nxdomain(self) -> None:
        for target in ("s-3.localhost", "wrong.localhost"):
            with self.subTest(target=target):
                self.assertEqual(self.query_counts(target, TYPE_A), (3, 0))

    def test_plain_localhost_is_not_an_advertised_target(self) -> None:
        self.assertEqual(self.query_counts("localhost", TYPE_A), (3, 0))


if __name__ == "__main__":
    unittest.main()
