"""P2P advertisement fixtures, including bounded and malformed wire responses."""

import importlib.util
import struct
import unittest
from pathlib import Path
from unittest.mock import patch

SPEC = importlib.util.spec_from_file_location(
    "probe", Path(__file__).parents[1] / "monero-p2p-rpc-port.py"
)
probe = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(probe)

# Independent portable-storage fixture: node_data object, rpc_port uint16.
RESTRICTED = bytes.fromhex("01110101010102010104096e6f64655f646174610c04087270635f706f727407a146")


class WireTests(unittest.TestCase):
    def test_restricted_port_is_observed(self):
        self.assertEqual(probe.advertised_port(RESTRICTED), 18081)

    def test_admin_advertisement_is_distinct(self):
        self.assertEqual(probe.advertised_port(RESTRICTED[:-2] + struct.pack("<H", 18085)), 18085)

    def test_missing_zero_and_bad_ports_are_unavailable(self):
        for data in (
            probe.STORAGE + b"\x00",
            RESTRICTED[:-2] + b"\x00\x00",
            RESTRICTED[:-3] + b"\x0b\x01",
        ):
            with self.subTest(data=data), self.assertRaises(ValueError):
                probe.advertised_port(data)

    def test_truncation_bad_header_and_trailing_bytes_fail(self):
        for data in (RESTRICTED[:-1], b"bad-header" + RESTRICTED[9:], RESTRICTED + b"\x00"):
            with self.subTest(data=data), self.assertRaises(ValueError):
                probe.advertised_port(data)

    def test_oversized_response_is_rejected_before_body_read(self):
        class Socket:
            def __enter__(self):
                return self

            def __exit__(self, *args):
                pass

            def sendall(self, data):
                pass

            def settimeout(self, timeout):
                pass

            def recv(self, size):
                return probe.HEADER.pack(probe.MAGIC, probe.MAX_BODY + 1, 0, 1001, 1, 2, 1)

        with (
            patch.object(probe.socket, "create_connection", return_value=Socket()),
            self.assertRaisesRegex(ValueError, "oversized"),
        ):
            probe.probe("fixture", 18080)

    def test_request_uses_mainnet_and_does_not_advertise_a_peer_port(self):
        request = probe.request()
        self.assertEqual(
            probe.HEADER.unpack(request[:33]), (probe.MAGIC, len(request) - 33, 1, 1001, 0, 1, 1)
        )
        reader = probe.Reader(request[33:])
        self.assertEqual(reader.take(9), probe.STORAGE)
        payload = reader.object()
        self.assertEqual(
            payload["node_data"]["network_id"], bytes.fromhex("1230f171610441611731008216a1a110")
        )
        self.assertEqual(payload["node_data"]["my_port"], 0)


if __name__ == "__main__":
    unittest.main()
