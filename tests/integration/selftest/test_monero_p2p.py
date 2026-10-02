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


# Independent encoder for small fixtures; never uses the production serializer.
def object_bytes(fields):
    if len(fields) >= 64:
        raise ValueError("fixture field bound")
    return bytes([len(fields) * 4]) + b"".join(
        bytes([len(name)]) + name.encode() + bytes([kind]) + value for name, kind, value in fields
    )


def handshake(port=18081, omit=False, node_override=None, sync_override=None):
    node = {
        "network_id": (10, b"\x40" + bytes.fromhex("1230f171610441611731008216a1a110")),
        "peer_id": (5, struct.pack("<Q", 42)),
        "my_port": (6, struct.pack("<I", 18080)),
    }
    if not omit:
        node["rpc_port"] = (7, struct.pack("<H", port))
    sync = {
        "current_height": (5, struct.pack("<Q", 1)),
        "cumulative_difficulty": (5, struct.pack("<Q", 1)),
        "top_id": (10, b"\x80" + b"x" * 32),
    }
    for fields, override in ((node, node_override), (sync, sync_override)):
        for key, value in (override or {}).items():
            if value is None:
                fields.pop(key, None)
            else:
                fields[key] = value
    return bytes.fromhex("011101010101020101") + object_bytes(
        [
            ("node_data", 12, object_bytes([(k, *v) for k, v in node.items()])),
            ("payload_data", 12, object_bytes([(k, *v) for k, v in sync.items()])),
        ]
    )


RESTRICTED = handshake()


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
        admin = handshake(18085)
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
        self.assertEqual(probe.advertised_port(handshake(18085)), 18085)

    def test_valid_suppression_is_a_decoded_zero(self):
        for data in (handshake(0), handshake(omit=True)):
            self.assertEqual(probe.advertised_port(data), 0)
            self.assertEqual(transcript_probe(frame(1001, data, 2, 1)), 0)

    def test_partial_or_malformed_handshakes_cannot_prove_suppression(self):
        malformed = (
            probe.STORAGE + b"\x00",
            # The old port-only fixture lacks required identity and core sync fields.
            bytes.fromhex("01110101010102010104096e6f64655f646174610c04087270635f706f7274070000"),
            handshake(0, node_override={"network_id": (10, b"\x40" + b"x" * 16)}),
            handshake(0, node_override={"peer_id": None}),
            handshake(0, node_override={"my_port": (11, b"\x01")}),
            handshake(0, node_override={"rpc_port": (11, b"\x00")}),
            handshake(0, sync_override={"current_height": None}),
            handshake(0, sync_override={"current_height": (5, b"\x00" * 8)}),
            handshake(0, sync_override={"cumulative_difficulty": None}),
            handshake(0, sync_override={"top_id": (10, b"\x04x")}),
        )
        for data in malformed:
            with self.subTest(data=data), self.assertRaises(ValueError):
                probe.advertised_port(data)

    def test_restricted_port_requires_complete_handshake_data(self):
        for data in (
            bytes.fromhex("01110101010102010104096e6f64655f646174610c04087270635f706f727407a146"),
            handshake(node_override={"peer_id": None}),
            handshake(sync_override={"top_id": None}),
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
                frame(1001, handshake(sync_override={"top_id": None}), 2, 1),
                "decode_handshake",
                "payload_data_invalid",
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
