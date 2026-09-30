#!/usr/bin/env python3
"""Observe a mainnet node's advertised RPC port through a bounded P2P handshake.

Wire definitions: Monero v0.18.5.1, p2p_protocol_defs.h, CORE_SYNC_DATA,
portable_storage_base.h and levin_base.h. No RPC login or peer list is printed.
"""

import json
import socket
import struct
import sys
import time

HEADER = struct.Struct("<QQBIiII")
MAGIC = 0x0101010101012101
STORAGE = bytes.fromhex("011101010101020101")
MAX_BODY = 262144


def varint(value):
    for tag, size in enumerate((1, 2, 4, 8)):
        if value < 1 << (size * 8 - 2):
            return ((value << 2) | tag).to_bytes(size, "little")
    raise ValueError("length exceeds portable storage bound")


def section(entries):
    return varint(len(entries)) + b"".join(
        bytes([len(key)]) + key.encode("ascii") + bytes([kind]) + value
        for key, kind, value in entries
    )


def blob(value):
    return varint(len(value)) + value


def request():
    node = section(
        [
            ("network_id", 10, blob(bytes.fromhex("1230f171610441611731008216a1a110"))),
            ("peer_id", 5, struct.pack("<Q", 0x50495448454144)),
            ("my_port", 6, struct.pack("<I", 0)),
            ("support_flags", 6, struct.pack("<I", 1)),
        ]
    )
    sync = section(
        [
            ("current_height", 5, struct.pack("<Q", 1)),
            ("cumulative_difficulty", 5, struct.pack("<Q", 1)),
            ("cumulative_difficulty_top64", 5, struct.pack("<Q", 0)),
            (
                "top_id",
                10,
                blob(
                    bytes.fromhex(
                        "418015bb9ae982a1975da7d79277c2705727a56894ba0fb246adaabb1f4632e3"
                    )
                ),
            ),
            ("top_version", 8, b"\x01"),
            ("pruning_seed", 6, struct.pack("<I", 0)),
        ]
    )
    body = STORAGE + section([("node_data", 12, node), ("payload_data", 12, sync)])
    return HEADER.pack(MAGIC, len(body), 1, 1001, 0, 1, 1) + body


class Reader:
    def __init__(self, data):
        if len(data) > MAX_BODY:
            raise ValueError("oversized portable storage")
        self.data = memoryview(data)
        self.offset = 0

    def take(self, size):
        if size < 0 or self.offset + size > len(self.data):
            raise ValueError("truncated portable storage")
        result = self.data[self.offset : self.offset + size].tobytes()
        self.offset += size
        return result

    def count(self):
        first = self.take(1)[0]
        size = 1 << (first & 3)
        return int.from_bytes(bytes([first]) + self.take(size - 1), "little") >> 2

    def value(self, kind, depth):
        if depth > 8:
            raise ValueError("portable storage nesting bound")
        if kind & 0x80:
            count = self.count()
            if count > MAX_BODY:
                raise ValueError("portable storage array bound")
            return [self.value(kind & 0x7F, depth + 1) for _ in range(count)]
        formats = {1: "q", 2: "i", 3: "h", 4: "b", 5: "Q", 6: "I", 7: "H", 8: "B", 9: "d", 11: "?"}
        if kind in formats:
            fmt = "<" + formats[kind]
            return struct.unpack(fmt, self.take(struct.calcsize(fmt)))[0]
        if kind == 10:
            return self.take(self.count())
        if kind == 12:
            return self.object(depth + 1)
        raise ValueError("unknown portable storage type")

    def object(self, depth=0):
        count = self.count()
        if count > 128:
            raise ValueError("portable storage field bound")
        result = {}
        for _ in range(count):
            key = self.take(self.take(1)[0]).decode("ascii")
            if key in result:
                raise ValueError("duplicate portable storage field")
            result[key] = self.value(self.take(1)[0], depth)
        return result


def storage_object(body):
    reader = Reader(body)
    if reader.take(len(STORAGE)) != STORAGE:
        raise ValueError("invalid portable storage header")
    result = reader.object()
    if reader.offset != len(body):
        raise ValueError("trailing portable storage data")
    return result


def advertised_port(body):
    node = storage_object(body).get("node_data")
    if not isinstance(node, dict):
        raise ValueError("handshake node_data missing")
    if "rpc_port" not in node:
        raise ValueError("handshake rpc_port omitted")
    port = node["rpc_port"]
    if type(port) is int and port == 0:
        raise ValueError("handshake rpc_port zero")
    if type(port) is not int or not 1 <= port <= 65535:
        raise ValueError("handshake rpc_port invalid")
    return port


def receive(sock, size, deadline):
    result = bytearray()
    while len(result) < size:
        remaining = deadline - time.monotonic()
        if remaining <= 0:
            raise TimeoutError("P2P probe deadline")
        sock.settimeout(remaining)
        chunk = sock.recv(size - len(result))
        if not chunk:
            raise ValueError("truncated P2P response")
        result.extend(chunk)
    return bytes(result)


ERROR_CODES = {
    "invalid P2P handshake response": "invalid_header",
    "oversized P2P handshake response": "oversized_header",
    "truncated P2P response": "truncated_response",
    "invalid portable storage header": "invalid_storage_header",
    "oversized portable storage": "oversized_storage",
    "truncated portable storage": "truncated_storage",
    "portable storage nesting bound": "nesting_bound",
    "portable storage array bound": "array_bound",
    "portable storage field bound": "field_bound",
    "unknown portable storage type": "unknown_storage_type",
    "duplicate portable storage field": "duplicate_field",
    "trailing portable storage data": "trailing_storage",
    "handshake node_data missing": "node_data_missing",
    "handshake rpc_port omitted": "rpc_port_omitted",
    "handshake rpc_port zero": "rpc_port_zero",
    "handshake rpc_port invalid": "rpc_port_invalid",
    "invalid txpool notification": "invalid_notification",
    "P2P notification bound": "notification_bound",
}


class ProbeFailure(ValueError):
    """Closed diagnostic fields: never include an exception's remote data or address."""

    def __init__(self, stage, error, metadata):
        if isinstance(error, TimeoutError):
            reason = "timeout"
        elif isinstance(error, ConnectionRefusedError):
            reason = "connection_refused"
        elif isinstance(error, OSError):
            reason = "transport_error"
        elif isinstance(error, UnicodeError):
            reason = "invalid_field_encoding"
        else:
            reason = ERROR_CODES.get(str(error), "invalid_data")
        self.observation = {"stage": stage, "error": reason, **metadata}
        super().__init__(json.dumps(self.observation, separators=(",", ":")))


def probe(host, port):
    deadline = time.monotonic() + 8
    stage, metadata = "connect", {}
    try:
        with socket.create_connection((host, port), timeout=8) as sock:
            stage = "send_request"
            sock.sendall(request())
            # v0.18.5.1 can queue NOTIFY_GET_TXPOOL_COMPLEMENT before its handshake
            # response. It needs no reply; never mistake it for handshake evidence.
            for frame in range(5):
                stage = "response_header"
                header = HEADER.unpack(receive(sock, HEADER.size, deadline))
                signature, size, wants_reply, command, code, flags, version = header
                metadata = {"command": command, "flags": flags, "code": code, "size": size}
                notification = command == 2010 and flags == 1 and code == 0
                response = command == 1001 and flags == 2 and code == 1
                if (
                    signature != MAGIC
                    or wants_reply != 0
                    or version != 1
                    or not (notification or response)
                ):
                    raise ValueError("invalid P2P handshake response")
                if size > MAX_BODY:
                    raise ValueError("oversized P2P handshake response")
                stage = "response_body"
                body = receive(sock, size, deadline)
                if response:
                    stage = "decode_handshake"
                    return advertised_port(body)
                stage = "decode_notification"
                data = storage_object(body)
                hashes = data.get("hashes", b"")
                if set(data) - {"hashes"} or not isinstance(hashes, bytes) or len(hashes) % 32:
                    raise ValueError("invalid txpool notification")
                if frame == 4:
                    raise ValueError("P2P notification bound")
    except (OSError, ValueError, UnicodeError) as error:
        raise ProbeFailure(stage, error, metadata) from None


def main(argv):
    try:
        print(probe(argv[1], int(argv[2])))
        return 0
    except ProbeFailure as error:
        # stdout survives capture by the container runner, whose stderr may go to journald.
        print("P2P advertised RPC port unavailable " + str(error))
        return 1
    except (IndexError, ValueError):
        print(
            'P2P advertised RPC port unavailable {"stage":"arguments","error":"invalid_arguments"}'
        )
        return 1


if __name__ == "__main__":
    sys.exit(main(sys.argv))
