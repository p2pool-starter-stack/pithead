import json
import struct
from unittest.mock import AsyncMock, MagicMock, patch

import pytest
from requests.auth import HTTPDigestAuth

from mining_dashboard.service import data_service as ds
from mining_dashboard.service.control_service import mask_secrets
from mining_dashboard.service.health import monero_backups as mb
from mining_dashboard.service.health.node_health import NodeHealthMonitor

READY = {"reachable": True, "is_syncing": False, "synchronized": True}
NODES = [
    {"host": "one.example", "rpc_port": 28081, "zmq_port": 28083, "rpc_login": "alice:pass:word"},
    {"host": "two.example", "rpc_port": 38081, "zmq_port": 38083},
]


def backups(monkeypatch, nodes=NODES):
    monkeypatch.setenv("MONERO_BACKUP_NODES", json.dumps(nodes))
    with patch.object(mb, "MoneroClient") as client:
        client.side_effect = [MagicMock(), MagicMock()][: len(nodes)]
        result = mb.MoneroBackups()
    return result


def test_each_node_gets_its_own_credentials_and_ports(monkeypatch):
    monkeypatch.setenv("MONERO_BACKUP_NODES", json.dumps(NODES))
    with patch.object(mb, "MoneroClient") as client:
        mb.MoneroBackups()
    assert client.call_args_list[0].args == ("http://one.example:28081", "alice", "pass:word")
    assert client.call_args_list[1].args == ("http://two.example:38081", "", "")


@pytest.mark.parametrize("status,expected", [(200, True), (401, False)])
def test_backup_rpc_uses_configured_digest_auth(monkeypatch, status, expected):
    monkeypatch.setenv("MONERO_BACKUP_NODES", json.dumps(NODES[:1]))
    pool = mb.MoneroBackups()
    response = MagicMock(status_code=status)
    response.json.return_value = {"synchronized": True, "height": 42}
    with (
        patch(
            "mining_dashboard.client.monero.monero_client.bounded_get", return_value=response
        ) as request,
        patch.object(mb, "zmq_publisher", return_value=True) as publisher,
    ):
        assert pool.usable({"reachable": False}) is expected
    auth = request.call_args.kwargs["auth"]
    assert isinstance(auth, HTTPDigestAuth)
    assert (auth.username, auth.password) == ("alice", "pass:word")
    assert request.call_args.kwargs["allow_redirects"] is False
    assert publisher.call_count == int(expected)


@pytest.mark.parametrize(
    "rpc,zmq,expected",
    [
        ([READY, READY], [False, True], True),
        ([READY, None], [False], False),
        ([dict(READY, synchronized=False), READY], [True], True),
        ([dict(READY, synchronized=False), None], [], False),
        ([dict(READY, is_syncing=True), None], [], False),
        ([None, None], [], False),
    ],
)
def test_one_individual_backup_must_pass_every_check(monkeypatch, rpc, zmq, expected):
    pool = backups(monkeypatch)
    for client, reply in zip(pool.clients, rpc, strict=True):
        client.get_sync_status.return_value = reply
    with patch.object(mb, "zmq_publisher", side_effect=zmq) as publisher:
        assert pool.usable({"reachable": False}) is expected
    assert all(call.args[0] in {n["host"] for n in NODES} for call in publisher.call_args_list)


def test_healthy_primary_does_not_wait_for_unavailable_backups(monkeypatch):
    pool = backups(monkeypatch)
    with patch.object(mb, "zmq_publisher", return_value=True) as publisher:
        assert pool.usable(READY)
    publisher.assert_called_once_with(*pool.primary)
    for client in pool.clients:
        client.get_sync_status.assert_not_called()


def test_primary_rpc_cannot_supply_backup_zmq(monkeypatch):
    pool = backups(monkeypatch)
    for client in pool.clients:
        client.get_sync_status.return_value = None
    with patch.object(mb, "zmq_publisher", return_value=False):
        assert not pool.usable(READY)


def test_mask_backup_credentials_without_hiding_endpoints():
    masked = mask_secrets({"monero": {"backup_nodes": [dict(NODES[0]), dict(NODES[1])]}})
    assert masked["monero"]["backup_nodes"][0]["rpc_login"] == {"__secret__": True}
    assert masked["monero"]["backup_nodes"][0]["host"] == "one.example"
    assert "rpc_login" not in masked["monero"]["backup_nodes"][1]


@pytest.mark.asyncio
async def test_aggregate_debounce_failover_and_confirmed_readmission(monkeypatch):
    monkeypatch.setenv("MONERO_BACKUP_NODES", json.dumps(NODES))
    sm = MagicMock()
    sm.load_snapshot.return_value = None
    svc = ds.DataService(sm, MagicMock(), MagicMock())
    svc.miner_released = True
    svc.docker_control.stop = AsyncMock(return_value=True)
    svc.docker_control.start = AsyncMock(return_value=True)
    now = [0]
    svc.monero_pool_health = NodeHealthMonitor(down_after=4, recovery_after=3, clock=lambda: now[0])
    with (
        patch.object(svc.monero_backups, "usable", return_value=True) as usable,
        patch.object(ds, "TARI_REQUIRED", False),
    ):
        assert not await svc._worker_monero_down({"reachable": False}, True)
        await svc._apply_worker_rejection(False)
        svc.docker_control.stop.assert_not_called()
        usable.return_value = False
        now[0] = 1
        assert not await svc._worker_monero_down({}, True)
        now[0] = 5
        down = await svc._worker_monero_down({}, True)
        assert down
        await svc._apply_worker_rejection(down)
        assert svc.workers_rejected
        usable.return_value = True
        now[0] = 6
        down = await svc._worker_monero_down({}, True)
        await svc._apply_worker_rejection(down)
        assert svc.workers_rejected
        now[0] = 9
        down = await svc._worker_monero_down({}, True)
        await svc._apply_worker_rejection(down)
        assert not svc.workers_rejected
        svc.docker_control.start.assert_awaited_once()


@pytest.mark.asyncio
async def test_no_backups_preserves_gate_and_initial_sync_hold(monkeypatch):
    monkeypatch.delenv("MONERO_BACKUP_NODES", raising=False)
    sm = MagicMock()
    sm.load_snapshot.return_value = None
    svc = ds.DataService(sm, MagicMock(), MagicMock())
    with patch.object(svc.monero_backups, "usable") as usable:
        assert await svc._worker_monero_down({}, True)
        assert not await svc._worker_monero_down({}, False)
        usable.assert_not_called()
    svc.monero_backups.nodes = NODES
    svc.docker_control.stop = AsyncMock(return_value=True)
    with patch.object(svc.monero_backups, "usable", return_value=True):
        assert not await svc._worker_monero_down({}, True)
        await svc._apply_sync_gate(False)
    assert not svc.miner_released
    assert svc.docker_control.stop.await_count > 0


def wire(kind=b"PUB"):
    greeting = b"\xff" + bytes(8) + b"\x7f\x03\x01NULL" + bytes(48)
    ready = b"\x05READY\x0bSocket-Type" + struct.pack("!I", len(kind)) + kind
    return greeting + bytes([4, len(ready)]) + ready


@pytest.mark.parametrize(
    "reply,expected",
    [
        (wire(), True),
        (wire(b"XPUB"), True),
        (wire(b"REP"), False),
        (bytes(64), False),
        (wire()[:65], False),
        (wire()[:64] + b"\x06\xff", False),
        (wire()[:64] + b"\x04\x07\x05READYx", False),
    ],
)
def test_zmq_protocol_checks(monkeypatch, reply, expected):
    pending = bytearray(reply)
    connection = MagicMock()

    def recv(size):
        chunk = bytes(pending[: min(size, 3)])
        del pending[: len(chunk)]
        return chunk

    connection.recv.side_effect = recv
    connection.__enter__.return_value = connection
    monkeypatch.setattr(mb.socket, "create_connection", lambda *a, **kw: connection)
    assert mb.zmq_publisher("node.example", 18083) is expected


def test_zmq_failure_and_deadline(monkeypatch):
    monkeypatch.setattr(mb.socket, "create_connection", MagicMock(side_effect=OSError))
    assert not mb.zmq_publisher("node.example", 18083)
    connection = MagicMock()
    connection.__enter__.return_value = connection
    monkeypatch.setattr(mb.socket, "create_connection", lambda *a, **kw: connection)
    monkeypatch.setattr(mb.time, "monotonic", MagicMock(side_effect=[0, 6]))
    assert not mb.zmq_publisher("node.example", 18083)
