import logging
from types import SimpleNamespace

import pytest

from mining_dashboard.config import config
from mining_dashboard.service.health.node_health import NodeHealthMonitor
from mining_dashboard.service.sync_status import SyncStatus, node_address


@pytest.mark.parametrize(
    "address, expected",
    [
        ("https://user:secret@node.example:443/rpc?key=secret", "node.example:443"),
        ("node.example:18142", "node.example:18142"),
        ("[::1]:18142", "[::1]:18142"),
        ("node.example", "node.example"),
        ("http://[invalid", None),
        ("http:///", None),
        ("node.example:bad", None),
    ],
)
def test_node_address_never_exposes_credentials(address, expected):
    assert node_address(address) == expected


def test_remote_wait_transitions_recovery_and_admission(monkeypatch, caplog):
    monkeypatch.setattr(config, "TARI_MODE", "remote")
    monkeypatch.setattr(config, "TARI_GRPC_ADDRESS", "remote.example:18142")
    monkeypatch.setattr(config, "MONERO_NODE_HOST", "remote.example")
    clock = [10.0]
    monitor = NodeHealthMonitor(clock=lambda: clock[0], recovery_after=60)
    service = SimpleNamespace(
        monero_health=monitor,
        tari_health=monitor,
        miner_released=False,
        miner_held=True,
        workers_rejected=False,
        fail_closed_held=False,
    )
    reporter = SyncStatus(clock=lambda: clock[0], wall_clock=lambda: 1000 + clock[0])
    monero = {"reachable": True, "synchronized": True, "is_syncing": False}
    tari = {"reachable": True, "initial_sync_achieved": False, "base_node_state": "HEADER_SYNC"}
    monitor.update(True)
    with caplog.at_level(logging.INFO, logger="SyncStatus"):
        first = reporter.observe(service, monero, tari)
        assert first["chains"]["monero"]["synced"] is True
        assert first["chains"]["monero"]["initial_sync_achieved"] is None
        assert first["chains"]["tari"]["initial_sync_achieved"] is False
        assert first["chains"]["tari"]["node"] == "remote.example:18142"
        assert first["chains"]["tari"]["recovery_remaining"] == 60
        assert first["mining"]["held"] is True
        assert len(caplog.records) == 2
        clock[0] += 30
        second = reporter.observe(service, monero, tari)
        assert second["chains"]["tari"]["wait_seconds"] == 30
        assert len(caplog.records) == 2
        tari.update(reachable=False, error="GetTipInfo probe failed")
        monitor.update(False)
        outage = reporter.observe(service, monero, tari)
        assert outage["chains"]["tari"]["error"] == "GetTipInfo probe failed"
        assert len(caplog.records) == 3
        tari["initializing"] = "migrating"
        initializing = reporter.observe(service, monero, tari)
        assert initializing["chains"]["tari"]["initializing"] == "migrating"
        assert "migrating" in caplog.records[-1].message
        tari.update(reachable=True, initial_sync_achieved=True, error=None)
        clock[0] += 1
        monitor.update(True)
        service.workers_rejected = True
        recovering = reporter.observe(service, monero, tari)
        assert recovering["chains"]["tari"]["wait_seconds"] == 0
        assert recovering["mining"]["workers_rejected"] is True
        clock[0] += 61
        monitor.update(True)
        service.miner_released = True
        service.miner_held = service.workers_rejected = False
        ready = reporter.observe(service, monero, tari)
        assert ready["chains"]["tari"]["healthy"] is True
        assert ready["chains"]["tari"]["recovery_remaining"] is None
        assert ready["chains"]["tari"]["service_recreated"] is None
        assert ready["mining"]["released"] is True


def test_off_tari_unknown_readings_and_probe_failure(monkeypatch):
    monkeypatch.setattr(config, "TARI_MODE", "off")
    service = SimpleNamespace(
        monero_health=NodeHealthMonitor(),
        miner_released=False,
        miner_held=False,
        workers_rejected=False,
        fail_closed_held=True,
    )
    reporter = SyncStatus()
    result = reporter.observe(service, {}, {})
    assert "tari" not in result["chains"]
    assert result["chains"]["monero"]["synced"] is None
    result = reporter.observe(service, {"reachable": False}, {})
    assert result["chains"]["monero"]["error"] == "RPC probe failed; no live response"
    result = reporter.observe(service, {"reachable": True, "is_syncing": False}, {})
    assert result["chains"]["monero"]["synced"] is True
