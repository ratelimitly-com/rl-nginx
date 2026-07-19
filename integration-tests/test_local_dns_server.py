#!/usr/bin/env python3
import struct
import sys
import tempfile
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


class DnsServerStateTests(unittest.TestCase):
    def setUp(self) -> None:
        self.state = tempfile.NamedTemporaryFile("w+", encoding="ascii")
        self.server = DnsServer(
            "127.0.0.1",
            15353,
            "rn-test.local",
            ["1:19080"],
            self.state.name,
        )

    def tearDown(self) -> None:
        self.state.close()

    def set_mode(self, mode: str) -> None:
        self.state.seek(0)
        self.state.truncate()
        self.state.write(mode)
        self.state.flush()

    def query_counts(self, name: str, qtype: int) -> tuple[int, int]:
        response = self.server.handle_query(build_query(name, qtype))
        self.assertIsNotNone(response)
        return response_counts(response)

    def test_missing_srv_returns_nxdomain_for_srv_owner(self) -> None:
        self.set_mode("missing-srv")
        self.assertEqual(
            self.query_counts("_ratelimitly._udp.rn-test.local", TYPE_SRV),
            (3, 0),
        )

    def test_bad_target_keeps_srv_but_makes_target_unresolvable(self) -> None:
        self.set_mode("bad-target")
        self.assertEqual(
            self.query_counts("_ratelimitly._udp.rn-test.local", TYPE_SRV),
            (0, 1),
        )
        self.assertEqual(self.query_counts("s-1.localhost", TYPE_A), (3, 0))

    def test_timeout_drops_the_query_without_a_response(self) -> None:
        self.set_mode("timeout")
        response = self.server.handle_query(
            build_query("_ratelimitly._udp.rn-test.local", TYPE_SRV)
        )
        self.assertIsNone(response)

    def test_normal_mode_can_be_restored_after_failure_mode(self) -> None:
        self.set_mode("missing-srv")
        self.assertEqual(
            self.query_counts("_ratelimitly._udp.rn-test.local", TYPE_SRV),
            (3, 0),
        )
        self.set_mode("normal")
        self.assertEqual(
            self.query_counts("_ratelimitly._udp.rn-test.local", TYPE_SRV),
            (0, 1),
        )


if __name__ == "__main__":
    unittest.main()
