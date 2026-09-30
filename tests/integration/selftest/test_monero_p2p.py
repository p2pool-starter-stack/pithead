"""P2P advertisement fixtures, including bounded and malformed wire responses."""

import contextlib
import importlib.util
import io
import json
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


def transcript_probe(data):
    class Socket:
        def __enter__(self):
            return self

        def __exit__(self, *args):
            pass

        def sendall(self, request):
            pass

        def settimeout(self, timeout):
            pass

        def recv(self, size):
            nonlocal data
            chunk, data = data[:size], data[size:]
            return chunk

    with patch.object(probe.socket, "create_connection", return_value=Socket()):
        return probe.probe("fixture", 18080)


def frame(command, body, flags=1, code=0, wants_reply=0):
    return (
        struct.pack("<QQBIiII", 0x0101010101012101, len(body), wants_reply, command, code, flags, 1)
        + body
    )


class WireTests(unittest.TestCase):
    def test_txpool_notification_precedes_actual_handshake(self):
        # Pinned Monero's empty txpool notification: both storage signatures, v1, no fields.
        notification = frame(2010, bytes.fromhex("01110101010102010100"))
        self.assertEqual(transcript_probe(notification + frame(1001, RESTRICTED, 2, 1)), 18081)
        admin = RESTRICTED[:-2] + struct.pack("<H", 18085)
        self.assertEqual(transcript_probe(notification + frame(1001, admin, 2, 1)), 18085)

    def test_notifications_never_substitute_for_a_handshake(self):
        empty = bytes.fromhex("01110101010102010100")
        for transcript, reason in (
            (frame(2010, empty), "truncated_response"),
            (frame(2010, empty) * 5 + frame(1001, RESTRICTED, 2, 1), "notification_bound"),
            (frame(2011, empty), "invalid_header"),
            (frame(2010, empty, wants_reply=1), "invalid_header"),
            (frame(2010, empty, flags=2, code=1), "invalid_header"),
            (frame(2010, b"private!!"), "invalid_storage_header"),
            # hashes must be a blob of whole 32-byte hashes, not a one-byte blob.
            (
                frame(2010, bytes.fromhex("01110101010102010104066861736865730a0400")),
                "invalid_notification",
            ),
        ):
            with self.subTest(reason=reason), self.assertRaises(probe.ProbeFailure) as caught:
                transcript_probe(transcript)
            self.assertEqual(caught.exception.observation["error"], reason)
            self.assertNotIn("private!!", str(caught.exception))

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

    def test_diagnostics_do_not_echo_transport_or_argument_values(self):
        for error in (TimeoutError("private-value"), OSError("private-value")):
            with (
                patch.object(probe.socket, "create_connection", side_effect=error),
                contextlib.redirect_stdout(io.StringIO()) as output,
            ):
                self.assertEqual(probe.main(["probe", "private-value", "18080"]), 1)
            text = output.getvalue()
            self.assertNotIn("private-value", text)
            self.assertLess(len(text), 512)
            self.assertEqual(json.loads(text[text.index("{") :])["stage"], "connect")
        with contextlib.redirect_stdout(io.StringIO()) as output:
            self.assertEqual(probe.main(["probe", "private-value", "private-value"]), 1)
        self.assertNotIn("private-value", output.getvalue())

    def test_header_body_and_decode_failures_have_distinct_stages(self):
        class Socket:
            def __init__(self, data):
                self.data = data

            def __enter__(self):
                return self

            def __exit__(self, *args):
                pass

            def sendall(self, data):
                pass

            def settimeout(self, timeout):
                pass

            def recv(self, size):
                chunk, self.data = self.data[:size], self.data[size:]
                return chunk

        cases = (
            (
                probe.HEADER.pack(probe.MAGIC, 0, 0, 1002, 1, 2, 1),
                "response_header",
                "invalid_header",
            ),
            (
                probe.HEADER.pack(probe.MAGIC, 1, 0, 1001, 1, 2, 1),
                "response_body",
                "truncated_response",
            ),
            (
                probe.HEADER.pack(probe.MAGIC, 9, 0, 1001, 1, 2, 1) + b"private!!",
                "decode_handshake",
                "invalid_storage_header",
            ),
            (
                probe.HEADER.pack(probe.MAGIC, len(RESTRICTED), 0, 1001, 1, 2, 1)
                + RESTRICTED[:-2]
                + b"\x00\x00",
                "decode_handshake",
                "rpc_port_zero",
            ),
        )
        for data, stage, reason in cases:
            with (
                self.subTest(stage=stage, reason=reason),
                patch.object(probe.socket, "create_connection", return_value=Socket(data)),
                contextlib.redirect_stdout(io.StringIO()) as output,
            ):
                self.assertEqual(probe.main(["probe", "fixture", "18080"]), 1)
                text = output.getvalue()
                self.assertNotIn("private!!", text)
                fields = json.loads(text[text.index("{") :])
                self.assertEqual((fields["stage"], fields["error"]), (stage, reason))
                self.assertEqual(fields["command"], probe.HEADER.unpack(data[:33])[3])


if __name__ == "__main__":
    unittest.main()
