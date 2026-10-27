import json
import os
import socket
import struct
import time

from mining_dashboard.client.monero.monero_client import MoneroClient
from mining_dashboard.config.config import MONERO_NODE_HOST


def zmq_publisher(host, port, timeout=5):
    deadline = time.monotonic() + timeout
    try:
        with socket.create_connection((host, port), timeout=timeout) as connection:

            def read(size):
                data = bytearray()
                while len(data) < size:
                    remaining = deadline - time.monotonic()
                    if remaining <= 0:
                        raise TimeoutError
                    connection.settimeout(remaining)
                    chunk = connection.recv(size - len(data))
                    if not chunk:
                        raise OSError
                    data.extend(chunk)
                return bytes(data)

            connection.sendall(b"\xff" + bytes(8) + b"\x7f\x03\x01NULL" + bytes(48))
            greeting = read(64)
            if not (
                greeting[0] == 255
                and greeting[9] == 127
                and greeting[10] >= 3
                and greeting[12:32] == b"NULL" + bytes(16)
                and greeting[32:] == bytes(32)
            ):
                return False
            connection.sendall(b"\x04\x19\x05READY\x0bSocket-Type\x00\x00\x00\x03SUB")
            flags, size = read(2)
            if flags & 6 != 4 or size > 64:
                return False
            ready = read(size)
            if not ready.startswith(b"\x05READY"):
                return False
            offset = 6
            while offset < size:
                length = ready[offset]
                offset += 1
                key = ready[offset : offset + length]
                offset += length
                value_length = struct.unpack("!I", ready[offset : offset + 4])[0]
                offset += 4
                value = ready[offset : offset + value_length]
                offset += value_length
                if offset > size:
                    return False
                if key == b"Socket-Type":
                    return value in (b"PUB", b"XPUB")
    except (OSError, ValueError, IndexError, struct.error):
        return False
    return False


def synced(status):
    return (
        isinstance(status, dict)
        and status.get("is_syncing") is False
        and status.get("synchronized") is True
    )


class MoneroBackups:
    def __init__(self):
        self.nodes = json.loads(os.environ.get("MONERO_BACKUP_NODES") or "[]")
        self.primary = (MONERO_NODE_HOST, int(os.environ.get("MONERO_ZMQ_PORT", "18083")))
        self.clients = []
        for node in self.nodes:
            user, _, password = node.get("rpc_login", "").partition(":")
            host = node["host"]
            url_host = f"[{host}]" if ":" in host else host
            self.clients.append(
                MoneroClient(f"http://{url_host}:{node['rpc_port']}", user, password)
            )

    def usable(self, primary_sync):
        if (
            primary_sync.get("reachable") is True
            and synced(primary_sync)
            and zmq_publisher(*self.primary)
        ):
            return True
        for node, client in zip(self.nodes, self.clients, strict=True):
            if synced(client.get_sync_status()) and zmq_publisher(node["host"], node["zmq_port"]):
                return True
        return False
