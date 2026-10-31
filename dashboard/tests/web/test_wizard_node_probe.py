"""The wizard proves remote endpoints with the protocols p2pool will consume."""

import asyncio
import json
import threading
from contextlib import contextmanager
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

import grpc
import pytest
from aiohttp.test_utils import TestClient, TestServer
from google.protobuf import empty_pb2

from mining_dashboard import wizard_node_probe
from mining_dashboard.client.tari.generated import base_node_pb2, base_node_pb2_grpc
from mining_dashboard.wizard import server as wizard


class _MonerodHandler(BaseHTTPRequestHandler):
    mode = "ok"
    saw_digest = False

    def do_GET(self):  # noqa: N802 — http.server's callback name
        auth = self.headers.get("Authorization", "")
        if self.mode == "auth" or (self.mode == "ok" and not auth.startswith("Digest ")):
            self.send_response(401)
            self.send_header("WWW-Authenticate", 'Digest realm="node", nonce="abc", qop="auth"')
            self.end_headers()
            return
        type(self).saw_digest = auth.startswith("Digest ")
        body = (
            b'{"status":"OK","height":42,"target_height":43,"nettype":"mainnet"}'
            if self.mode == "ok"
            else b'{"status":"OK"}'
            if self.mode == "thin"
            else b"not monerod"
        )
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, _format, *_args):
        pass


@contextmanager
def _monerod(mode):
    handler = type("Handler", (_MonerodHandler,), {"mode": mode, "saw_digest": False})
    server = ThreadingHTTPServer(("127.0.0.1", 0), handler)
    thread = threading.Thread(target=server.serve_forever, daemon=True)
    thread.start()
    try:
        yield server.server_port, handler
    finally:
        server.shutdown()
        thread.join()


async def _zmq_server(reply, socket_type=b"PUB"):
    async def answer(reader, writer):
        await reader.readexactly(64)
        writer.write(reply)
        await writer.drain()
        if len(reply) == 64:
            await reader.readexactly(len(wizard_node_probe._ZMTP_READY))
            ready = b"\x05READY\x0bSocket-Type" + len(socket_type).to_bytes(4, "big") + socket_type
            writer.write(bytes((0x04, len(ready))) + ready)
            await writer.drain()
        writer.close()
        await writer.wait_closed()

    return await asyncio.start_server(answer, "127.0.0.1", 0)


class _TariNode(base_node_pb2_grpc.BaseNodeServicer):
    async def GetTipInfo(self, request, context):  # noqa: N802 — generated gRPC method
        assert request.SerializeToString() == empty_pb2.Empty().SerializeToString()
        return base_node_pb2.TipInfoResponse(initial_sync_achieved=True)


async def _tari_server():
    server = grpc.aio.server()
    base_node_pb2_grpc.add_BaseNodeServicer_to_server(_TariNode(), server)
    port = server.add_insecure_port("127.0.0.1:0")
    await server.start()
    return server, port


def _candidate(**overrides):
    cfg = {
        "monero": {
            "mode": "remote",
            "remote": {"host": "127.0.0.1", "rpc_port": 18081, "zmq_port": 18083},
            "node_username": "node-user",
            "node_password": "node-pass",
        },
        "tari": {"mode": "off"},
        "network": {"tor_egress_firewall": True},
    }
    cfg.update(overrides)
    return cfg


@pytest.fixture
def allow_test_loopback(monkeypatch):
    async def allowed(host, _port, _firewall):
        return host

    monkeypatch.setattr(wizard_node_probe, "_resolved_address", allowed)


async def test_all_local_is_a_complete_zero_of_zero_report():
    assert await wizard_node_probe.probe_remote_nodes(
        {"monero": {"mode": "local"}, "tari": {"mode": "off"}}
    ) == {"ok": True, "configured": 0, "probed": 0, "probes": []}


@pytest.mark.usefixtures("allow_test_loopback")
async def test_monero_probe_uses_configured_digest_login_and_live_rpc_and_zmq():
    greeting = wizard_node_probe._ZMTP_GREETING
    zmq = await _zmq_server(greeting)
    zmq_port = zmq.sockets[0].getsockname()[1]
    try:
        with _monerod("ok") as (rpc_port, handler):
            cfg = _candidate()
            cfg["monero"]["remote"].update(rpc_port=rpc_port, zmq_port=zmq_port)
            report = await wizard_node_probe.probe_remote_nodes(cfg)
    finally:
        zmq.close()
        await zmq.wait_closed()
    assert report["ok"] is True
    assert [row["checked"] for row in report["probes"]] == ["rpc", "zmq"]
    assert all(row["ok"] is True for row in report["probes"])
    assert handler.saw_digest is True


@pytest.mark.usefixtures("allow_test_loopback")
@pytest.mark.parametrize(
    ("mode", "reason"),
    [("wrong-protocol", "protocol"), ("thin", "protocol"), ("auth", "auth")],
)
async def test_wrong_monero_protocol_and_auth_fail_instead_of_passing(mode, reason):
    with _monerod(mode) as (rpc_port, _handler):
        cfg = _candidate()
        cfg["monero"]["remote"].update(rpc_port=rpc_port, zmq_port=rpc_port)
        report = await wizard_node_probe.probe_remote_nodes(cfg)
    rpc = report["probes"][0]
    assert rpc["ok"] is False
    assert rpc["reason"] == reason
    assert report["ok"] is False


@pytest.mark.usefixtures("allow_test_loopback")
async def test_wrong_zmq_protocol_fails_a_live_open_port():
    server = await _zmq_server(b"this is not a ZMTP greeting")
    port = server.sockets[0].getsockname()[1]
    try:
        ok, reason, _detail = await wizard_node_probe._monero_zmq("127.0.0.1", port)
    finally:
        server.close()
        await server.wait_closed()
    assert ok is False
    assert reason == "protocol"


@pytest.mark.usefixtures("allow_test_loopback")
async def test_zmtp_prefix_without_a_complete_greeting_never_passes():
    server = await _zmq_server(wizard_node_probe._ZMTP_GREETING[:12])
    port = server.sockets[0].getsockname()[1]
    try:
        ok, reason, _detail = await wizard_node_probe._monero_zmq("127.0.0.1", port)
    finally:
        server.close()
        await server.wait_closed()
    assert (ok, reason) == (False, "protocol")


@pytest.mark.usefixtures("allow_test_loopback")
async def test_zmtp_ready_requires_a_publication_capable_peer():
    server = await _zmq_server(wizard_node_probe._ZMTP_GREETING, b"SUB")
    port = server.sockets[0].getsockname()[1]
    try:
        ok, reason, _detail = await wizard_node_probe._monero_zmq("127.0.0.1", port)
    finally:
        server.close()
        await server.wait_closed()
    assert (ok, reason) == (False, "protocol")


async def test_success_binds_the_candidate_to_the_address_that_was_probed(monkeypatch):
    calls = []

    async def resolved(_host, _port, _firewall):
        calls.append(_host)
        return "10.20.30.40"

    monkeypatch.setattr(wizard_node_probe, "_resolved_address", resolved)
    monkeypatch.setattr(wizard_node_probe, "_monero_rpc", lambda *_args: (True, "ok", "rpc"))

    async def zmq(*_args):
        return True, "ok", "zmq"

    monkeypatch.setattr(wizard_node_probe, "_monero_zmq", zmq)
    cfg = _candidate()
    cfg["monero"]["remote"]["host"] = "node.example"
    assert (await wizard_node_probe.probe_remote_nodes(cfg))["ok"] is True
    assert calls == ["node.example"]
    assert cfg["monero"]["remote"]["host"] == "10.20.30.40"


@pytest.mark.usefixtures("allow_test_loopback")
async def test_tari_probe_calls_the_real_base_node_grpc_method():
    server, port = await _tari_server()
    try:
        cfg = _candidate(
            monero={"mode": "local"},
            tari={"mode": "remote", "remote": {"host": "127.0.0.1", "grpc_port": port}},
        )
        report = await wizard_node_probe.probe_remote_nodes(cfg)
    finally:
        await server.stop(None)
    assert report["ok"] is True
    assert report["probes"][0]["checked"] == "grpc"


@pytest.mark.usefixtures("allow_test_loopback")
async def test_tari_wrong_protocol_and_refused_endpoint_never_pass():
    wrong = await asyncio.start_server(lambda _r, w: w.close(), "127.0.0.1", 0)
    wrong_port = wrong.sockets[0].getsockname()[1]
    closed = await asyncio.start_server(lambda _r, w: w.close(), "127.0.0.1", 0)
    closed_port = closed.sockets[0].getsockname()[1]
    closed.close()
    await closed.wait_closed()
    try:
        for port in (wrong_port, closed_port):
            cfg = _candidate(
                monero={"mode": "local"},
                tari={"mode": "remote", "remote": {"host": "127.0.0.1", "grpc_port": port}},
            )
            report = await wizard_node_probe.probe_remote_nodes(cfg)
            assert report["ok"] is False
            assert report["probes"][0]["reason"] == "unusable"
    finally:
        wrong.close()
        await wrong.wait_closed()


@pytest.mark.parametrize("host", ["localhost", "127.0.0.2", "::1"])
async def test_loopback_spellings_are_refused_before_a_probe(host):
    failure = await wizard_node_probe._resolved_address(host, 18081, True)
    assert isinstance(failure, tuple)
    assert failure[0] == "address"
    assert "container" in failure[1]


async def test_tor_firewall_policy_accepts_the_private_ranges_the_consumer_can_dial():
    assert await wizard_node_probe._resolved_address("10.20.30.40", 18081, True) == "10.20.30.40"


@pytest.fixture
def spool(tmp_path, monkeypatch):
    path = tmp_path / "spool"
    path.mkdir()
    monkeypatch.setenv("WIZARD_SPOOL", str(path))
    monkeypatch.setenv("WIZARD_TOKEN", "pit-X7KM2Q")
    reference = {
        "monero": {
            "mode": "local",
            "wallet_address": "",
            "node_username": "",
            "node_password": "",
            "remote": {"host": "node.example", "rpc_port": 18081, "zmq_port": 18083},
        },
        "tari": {"mode": "local", "wallet_address": ""},
        "network": {"tor_egress_firewall": True},
        "p2pool": {"pool": "mini"},
    }
    path.joinpath("config.reference.json").write_text(json.dumps(reference))
    return path


@pytest.fixture
async def client(spool):
    client = TestClient(TestServer(wizard.make_app(exit_fn=lambda code: None)))
    await client.start_server()
    await client.post("/auth", data={"token": "pit-X7KM2Q"}, allow_redirects=False)
    yield client
    await client.close()


async def test_failed_submit_returns_the_report_and_keeps_fields_without_a_candidate(
    client, spool, monkeypatch
):
    report = {
        "ok": False,
        "configured": 1,
        "probed": 1,
        "probes": [
            {
                "target": "monero",
                "host": "node.example",
                "port": 18081,
                "ok": False,
                "checked": "rpc",
                "reason": "auth",
                "detail": "The Monero node rejected the configured RPC login.",
                "elapsed_ms": 2,
            }
        ],
    }

    async def failed(_cfg):
        return report

    monkeypatch.setattr(wizard, "probe_remote_nodes", failed)
    cfg = {
        "monero": {
            "mode": "remote",
            "wallet_address": "",
            "node_username": "alice",
            "node_password": "secret",
            "remote": {"host": "node.example", "rpc_port": 18081, "zmq_port": 18083},
        },
        "tari": {"mode": "off", "wallet_address": ""},
        "network": {"tor_egress_firewall": True},
        "p2pool": {"pool": "mini"},
    }
    response = await client.post("/submit", data={"config": json.dumps(cfg)})
    body = await response.json()
    assert response.status == 400
    assert body["node_probe"] == report
    assert json.loads(spool.joinpath("last-attempt.json").read_text()) == cfg
    assert json.loads(spool.joinpath("node-probe.json").read_text()) == report
    assert not spool.joinpath("config.json").exists()


async def test_new_submission_clears_a_stale_probe_even_when_its_json_is_invalid(client, spool):
    spool.joinpath("node-probe.json").write_text(json.dumps({"ok": False}))
    response = await client.post("/submit", data={"config": "not json"})
    assert response.status == 400
    assert not spool.joinpath("node-probe.json").exists()


async def test_install_trigger_is_absent_until_the_probe_accepts(client, spool, monkeypatch):
    spool.joinpath("disks.tsv").write_text("sda\t1T\tDisk\tSERIAL\tempty\n")
    entered, release = asyncio.Event(), asyncio.Event()

    async def blocked(_cfg):
        entered.set()
        await release.wait()
        return {"ok": False, "configured": 1, "probed": 0, "probes": []}

    monkeypatch.setattr(wizard, "probe_remote_nodes", blocked)
    cfg = _candidate(monero={"mode": "remote", "remote": {"host": "node.example"}})
    pending = asyncio.create_task(
        client.post(
            "/submit",
            data={"config": json.dumps(cfg), "disk": "sda", "confirm": "sda", "wipe": "all"},
        )
    )
    await entered.wait()
    assert not spool.joinpath("install-request").exists()
    assert not spool.joinpath("config.json").exists()
    release.set()
    assert (await pending).status == 400
    assert not spool.joinpath("install-request").exists()
