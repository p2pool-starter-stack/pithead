"""Tiny SOCKS5 CONNECT fake for contract tests."""

import select
import socket
import socketserver
import threading


class _Server(socketserver.ThreadingTCPServer):
    allow_reuse_address = True
    daemon_threads = True


class _Handler(socketserver.BaseRequestHandler):
    def handle(self):
        client = self.request
        client.recv(2)
        client.recv(1)
        client.sendall(b"\x05\x00")
        _, _, _, kind = client.recv(4)
        if kind == 1:
            address = socket.inet_ntoa(client.recv(4))
        else:
            address = client.recv(client.recv(1)[0]).decode()
        port = int.from_bytes(client.recv(2), "big")
        if self.server.owner.refuse:
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
