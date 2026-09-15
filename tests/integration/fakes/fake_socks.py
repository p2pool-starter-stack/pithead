"""Tiny SOCKS5 CONNECT fake for contract tests."""

import select
import socket
import socketserver
import threading


class _Server(socketserver.ThreadingTCPServer):
    allow_reuse_address = True
    daemon_threads = True


def _read(sock, size):
    data = bytearray()
    while len(data) < size:
        if not (chunk := sock.recv(size - len(data))):
            raise ConnectionError("short SOCKS request")
        data.extend(chunk)
    return bytes(data)


class _Handler(socketserver.BaseRequestHandler):
    def handle(self):
        client = self.request
        _, methods = _read(client, 2)
        _read(client, methods)
        client.sendall(b"\x05\x00")
        _, _, _, kind = _read(client, 4)
        if kind == 1:
            address = socket.inet_ntoa(_read(client, 4))
        else:
            address = _read(client, _read(client, 1)[0]).decode()
        port = int.from_bytes(_read(client, 2), "big")
        owner = self.server.owner
        owner.connected = True
        if owner.refuse:
            client.sendall(b"\x05\x05\x00\x01" + b"\x00" * 6)
            return
        try:
            target = socket.create_connection((address, port))
        except OSError:
            client.sendall(b"\x05\x05\x00\x01" + b"\x00" * 6)
            return
        client.sendall(b"\x05\x00\x00\x01" + b"\x00" * 6)
        while ready := select.select((client, target), (), (), 1)[0]:
            for source in ready:
                if not (data := source.recv(65536)):
                    return
                (target if source is client else client).sendall(data)


class FakeSocks:
    """A loopback SOCKS5 listener that either relays CONNECT or refuses it."""

    def __init__(self, refuse=False):
        self.refuse = refuse
        self.connected = False
        self._server = _Server(("127.0.0.1", 0), _Handler)
        self._server.owner = self
        self.host, self.port = self._server.server_address

    @property
    def proxies(self):
        url = f"socks5h://{self.host}:{self.port}"
        return {"http": url, "https": url}

    def __enter__(self):
        self._thread = threading.Thread(target=self._server.serve_forever, daemon=True)
        self._thread.start()
        return self

    def __exit__(self, *_exc):
        self._server.shutdown()
        self._server.server_close()
