import json
import pathlib
import socket
import subprocess
import sys
import time

import pytest
import socks

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent))

from fake_socks import FakeSocks  # noqa: E402
from fake_stratum import FakeStratum  # noqa: E402


def send(client, method, params, request_id=1):
    client.sendall(
        json.dumps({"id": request_id, "method": method, "params": params}).encode() + b"\n"
    )


def receive(client):
    data = b""
    while not data.endswith(b"\n"):
        chunk = client.recv(1)
        assert chunk, "stratum closed before reply"
        data += chunk
    return json.loads(data)


def login(client, user="donor"):
    observed = {"login": user, "pass": "test-password", "agent": "contract-client"}
    send(client, "login", observed)
    response = receive(client)
    assert response["id"] == 1
    assert response["jsonrpc"] == "2.0"
    assert response["result"]["status"] == "OK"
    return observed, response["result"]


def submit(client, result):
    params = {
        "id": result["id"],
        "job_id": result["job"]["job_id"],
        "nonce": "00000000",
        "result": "00" * 32,
    }
    send(client, "submit", params, request_id=2)
    return params


@pytest.mark.parametrize("mode", ["accept", "reject"])
def test_login_job_and_submit_counters(mode):
    with (
        FakeStratum(mode) as fake,
        socket.create_connection((fake.host, fake.port), timeout=2) as client,
    ):
        observed, result = login(client)
        assert result["job"] == {
            "blob": "10" + "00" * 75,
            "job_id": "1",
            "target": "ffffffff",
            "algo": "rx/0",
            "height": 1,
            "seed_hash": "00" * 32,
        }
        params = submit(client, result)
        reply = receive(client)
        assert reply["id"] == 2
        if mode == "accept":
            assert reply["result"] == {"status": "OK"}
            assert reply["error"] is None
        else:
            assert reply["error"] == {"message": "Low diff share"}
        assert fake.accepted == (mode == "accept")
        assert fake.rejected == (mode == "reject")
        assert fake.submissions == [params]
        assert fake.logins == [observed]
        assert fake.host == "127.0.0.1" and fake.port != 0
        assert fake.fixture_metadata == {"url": f"{fake.host}:{fake.port}", "coin": "monero"}
        assert not ({"url", "coin", "user"} & fake.logins[0].keys())


def test_two_users_have_separate_login_records():
    with FakeStratum() as fake:
        for user in ("first", "second"):
            with socket.create_connection((fake.host, fake.port), timeout=2) as client:
                login(client, user)
        assert [record["login"] for record in fake.logins] == ["first", "second"]


@pytest.mark.parametrize("kwargs", [{"mode": "refuse"}, {"refuse": True}])
def test_refuse_closes_new_connection(kwargs):
    with (
        FakeStratum(**kwargs) as fake,
        socket.create_connection((fake.host, fake.port), timeout=2) as client,
    ):
        assert client.recv(1) == b""
        assert fake.logins == []


def test_silent_submit_stays_connected_without_reply():
    with (
        FakeStratum("silent") as fake,
        socket.create_connection((fake.host, fake.port), timeout=2) as client,
    ):
        _, result = login(client)
        params = submit(client, result)
        client.settimeout(0.2)
        with pytest.raises(TimeoutError):
            client.recv(1)
        deadline = time.monotonic() + 2
        while not fake.submissions and time.monotonic() < deadline:
            time.sleep(0.01)
        assert fake.submissions == [params]
        assert fake.accepted == fake.rejected == 0


def test_login_and_share_through_socks_relay():
    with FakeStratum() as fake, FakeSocks() as relay, socks.socksocket() as client:
        client.settimeout(2)
        client.set_proxy(socks.SOCKS5, relay.host, relay.port, rdns=True)
        client.connect((fake.host, fake.port))
        observed, result = login(client, "relayed-user")
        submit(client, result)
        assert receive(client)["result"]["status"] == "OK"
        assert fake.logins == [observed]
        assert relay.connected is True
        assert fake.accepted == 1


def test_bad_requests_do_not_kill_listener():
    with FakeStratum() as fake:
        for payload in (b"not-json\n", b"[]\n", b'{"params":[]}\n', b"x" * 65537):
            with socket.create_connection((fake.host, fake.port), timeout=2) as client:
                client.sendall(payload)
                try:
                    assert client.recv(1) == b""
                except ConnectionResetError:
                    pass
        with socket.create_connection((fake.host, fake.port), timeout=2) as client:
            send(client, "submit", {})
            assert "error" in receive(client)
            login(client)


def test_shutdown_closes_idle_connection():
    with FakeStratum() as fake:
        client = socket.create_connection((fake.host, fake.port), timeout=2)
        login(client)
    with client:
        assert client.recv(1) == b""


def test_unknown_mode_is_rejected():
    with pytest.raises(ValueError, match="unknown stratum mode"):
        FakeStratum("typo")


@pytest.mark.parametrize("explicit_host", [False, True])
def test_standalone_port_and_log(tmp_path, explicit_host):
    log = tmp_path / "stratum.jsonl"
    process = subprocess.Popen(  # noqa: S603
        [
            sys.executable,
            str(pathlib.Path(__file__).with_name("fake_stratum.py")),
            "--port",
            "0",
            "--log",
            str(log),
            *(["--host", "0.0.0.0"] if explicit_host else []),
        ],
        stdout=subprocess.PIPE,
        text=True,
    )
    try:
        import select

        assert select.select([process.stdout], [], [], 5)[0], "standalone listener did not start"
        metadata = json.loads(process.stdout.readline())["fixture_metadata"]
        host, port = metadata["url"].split(":")
        assert host == ("0.0.0.0" if explicit_host else "127.0.0.1")
        with socket.create_connection(("127.0.0.1", int(port)), timeout=2) as client:
            observed, result = login(client)
            submit(client, result)
            receive(client)
        events = [json.loads(line) for line in log.read_text().splitlines()]
        assert events == [
            {"event": "login", "observed": observed},
            {"event": "submit", "observed": {"outcome": "accept"}},
        ]
    finally:
        process.terminate()
        process.communicate(timeout=5)
