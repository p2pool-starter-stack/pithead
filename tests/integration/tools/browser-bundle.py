#!/usr/bin/env python3
import base64
import http.client
import io
import json
import re
import socket
import ssl
import sys
import tarfile
import time


def require(condition):
    if not condition:
        raise AssertionError("browser bundle assertion failed")


SERVICES = {
    "tor",
    "monerod",
    "tari",
    "p2pool",
    "xmrig-proxy",
    "dashboard",
    "docker-proxy",
    "docker-control",
    "caddy",
}


def verify_archive(data, password):
    with tarfile.open(fileobj=io.BytesIO(data), mode="r:gz") as archive:
        require(
            set(archive.getnames()) == {"doctor.json", *(f"logs/{name}.log" for name in SERVICES)}
        )
        for member in archive.getmembers():
            require(member.isfile() and member.mode == 0o600)
            payload = archive.extractfile(member).read()
            require(password.encode() not in payload)
            require(not re.search(rb"[a-z2-7]{56}\.onion", payload))
            if member.name == "doctor.json":
                require(isinstance(json.loads(payload).get("checks"), list))
            else:
                require(len(payload) <= 65536)


def verify(request, password, wait=time.sleep, deadline_seconds=240):
    status, _, _ = request("POST", "/api/control/diag-bundle", {}, authenticated=False)
    require(status == 401)
    status, _, _ = request("POST", "/api/control/diag-bundle", {}, control=False)
    require(status == 403)
    status, data, _ = request("POST", "/api/control/diag-bundle", {})
    require(status == 202)
    rid = json.loads(data)["id"]
    deadline = time.monotonic() + deadline_seconds
    while time.monotonic() < deadline:
        status, data, _ = request("GET", f"/api/control/result?id={rid}", None)
        if status == 202:
            wait(2)
            continue
        require(status == 200)
        result = json.loads(data)
        require(result["status"] == "applied" and result["kind"] == "diag-bundle")
        require(set(result["bundle"]["logs"]) == SERVICES)
        break
    else:
        raise AssertionError("bundle request did not finish within the bound")
    status, _, _ = request("POST", "/api/control/bundle-download", {"id": rid, "reviewed": False})
    require(status == 400)
    status, data, headers = request(
        "POST", "/api/control/bundle-download", {"id": rid, "reviewed": True}
    )
    require(status == 200 and headers.get("cache-control") == "no-store")
    require(headers.get("content-type", "").startswith("application/gzip"))
    verify_archive(data, password)


class LoopbackHTTPSConnection(http.client.HTTPSConnection):
    def connect(self):
        sock = socket.create_connection(("127.0.0.1", self.port), self.timeout, self.source_address)
        try:
            self.sock = self._context.wrap_socket(sock, server_hostname=self.host)
        except BaseException:
            sock.close()
            raise


def transport(settings):
    def request(method, path, body, *, control=True, authenticated=True):
        if settings["secure"]:
            connection = LoopbackHTTPSConnection(
                settings["host"],
                settings["port"],
                timeout=20,
                context=ssl._create_unverified_context(),  # noqa: S323
            )
        else:
            connection = http.client.HTTPConnection("127.0.0.1", settings["port"], timeout=20)
        headers = {
            "Content-Type": "application/json",
            "Host": f"{settings['host']}:{settings['port']}",
        }
        if authenticated:
            pair = f"{settings['username']}:{settings['password']}".encode()
            headers["Authorization"] = "Basic " + base64.b64encode(pair).decode()
        if control:
            headers["X-Pithead-Control"] = "1"
        try:
            connection.request(
                method, path, body=None if body is None else json.dumps(body), headers=headers
            )
            response = connection.getresponse()
            data = response.read(2 * 1024 * 1024 + 1)
            require(len(data) <= 2 * 1024 * 1024)
            return (
                response.status,
                data,
                dict((key.lower(), value) for key, value in response.getheaders()),
            )
        finally:
            connection.close()

    return request


def selftest():
    from unittest.mock import MagicMock, patch

    context, sock = MagicMock(), MagicMock()
    connection = LoopbackHTTPSConnection("fixture.example", 443, timeout=20)
    connection._context = context
    with patch("socket.create_connection", return_value=sock) as dial:
        connection.connect()
        dial.assert_called_once_with(("127.0.0.1", 443), 20, None)
        context.wrap_socket.assert_called_once_with(sock, server_hostname="fixture.example")
        context.wrap_socket.side_effect = OSError("fixture handshake failure")
        try:
            connection.connect()
        except OSError:
            pass
        else:
            raise AssertionError("handshake failure was swallowed")
        sock.close.assert_called_once()

    def fixture(extra=None, doctor=None, log="redacted", mode=0o600):
        data = io.BytesIO()
        reports = {"doctor.json": json.dumps(doctor if doctor is not None else {"checks": []})}
        reports.update({f"logs/{name}.log": log for name in SERVICES})
        reports.update(extra or {})
        with tarfile.open(fileobj=data, mode="w:gz") as archive:
            for name, text in reports.items():
                entry = tarfile.TarInfo(name)
                entry.size = len(text.encode())
                entry.mode = mode
                archive.addfile(entry, io.BytesIO(text.encode()))
        return data.getvalue()

    verify_archive(fixture(), "fixture-password")
    for data in [
        fixture(extra={"logs/wallet-rpc.log": "wallet"}),
        fixture(log="fixture-password"),
        fixture(log="a" * 56 + ".onion"),
        fixture(log="x" * 65537),
        fixture(doctor={}),
        fixture(mode=0o644),
    ]:
        try:
            verify_archive(data, "fixture-password")
        except AssertionError:
            continue
        raise AssertionError("unsafe fixture was accepted")
    calls = []

    def request(method, path, body, *, control=True, authenticated=True):
        calls.append(path)
        if not authenticated:
            return 401, b"", {}
        if not control:
            return 403, b"", {}
        if path.endswith("diag-bundle"):
            return 202, b'{"id":"fixture-id"}', {}
        if "/result?" in path:
            return (
                200,
                json.dumps(
                    {
                        "status": "applied",
                        "kind": "diag-bundle",
                        "bundle": {"logs": dict.fromkeys(SERVICES, "")},
                    }
                ).encode(),
                {},
            )
        if not body["reviewed"]:
            return 400, b"", {}
        return 200, fixture(), {"cache-control": "no-store", "content-type": "application/gzip"}

    verify(request, "fixture-password")
    require(len(calls) == 6)
    print("browser bundle probe: archive and authorization negative controls passed")


if __name__ == "__main__":
    if sys.argv[1:] == ["--self-test"]:
        selftest()
    else:
        try:
            settings = json.load(sys.stdin)
            verify(transport(settings), settings["password"])
        except Exception:
            print("browser bundle proof failed; private response details omitted", file=sys.stderr)
            sys.exit(1)
        print("browser bundle: authorized, bounded, redacted and reviewed archive verified")
