"""Clearnet sync waits for host firewall proof before the Tor restart (#2678)."""

import json
from unittest.mock import AsyncMock, MagicMock

from mining_dashboard.config import config
from mining_dashboard.service.network.clearnet_sync import ClearnetSyncSupervisor


def make_supervisor(tmp_path, monkeypatch, *, start=True, events=None):
    monkeypatch.setattr(config, "DASHBOARD_CONTROL_ENABLED", False)
    monkeypatch.setattr(config, "CONTROL_RESULTS_DIR", str(tmp_path / "results"))
    (tmp_path / "results").mkdir(exist_ok=True)
    dc = MagicMock()
    dc.stop = AsyncMock(return_value=True)
    dc.start = AsyncMock(return_value=start)
    cb = None if events is None else lambda name, ok: events.append((name, ok))  # noqa: E731
    return ClearnetSyncSupervisor(str(tmp_path), dc, on_transition=cb), dc


def host_result(tmp_path, chain, status="applied"):
    request = next((tmp_path / "requests").glob("*.json"))
    data = json.loads(request.read_text())
    assert data == {"id": data["id"], "action": "egress-sync", "chain": chain}
    (tmp_path / "results" / request.name).write_text(json.dumps({"status": status, "chain": chain}))
    request.unlink()


async def test_private_default_and_unsynced_node_do_not_request_refresh(tmp_path, monkeypatch):
    sup, dc = make_supervisor(tmp_path, monkeypatch)
    assert await sup.maybe_transition("monero", "monerod", False, True) is False
    assert await sup.maybe_transition("tari", "tari", True, False) is True
    assert not (tmp_path / "requests").exists()
    dc.stop.assert_not_called()


async def test_marker_then_host_proof_then_tor_restart(tmp_path, monkeypatch):
    events = []
    sup, dc = make_supervisor(tmp_path, monkeypatch, events=events)
    assert await sup.maybe_transition("monero", "monerod", True, True) is True
    assert (tmp_path / "monero.synced").exists()
    dc.stop.assert_not_called()
    host_result(tmp_path, "monero")
    assert await sup.maybe_transition("monero", "monerod", True, True) is False
    assert (tmp_path / "monero.synced.tor").exists()
    dc.stop.assert_awaited_once()
    dc.start.assert_awaited_once()
    assert dc.stop.await_args.kwargs["request_timeout"] > dc.stop.await_args.kwargs["stop_timeout"]
    assert events == [("monero", True)]
    assert await sup.maybe_transition("monero", "monerod", True, True) is False
    dc.stop.assert_awaited_once()


async def test_failed_refresh_retries_without_restart_or_rearm(tmp_path, monkeypatch):
    events = []
    sup, dc = make_supervisor(tmp_path, monkeypatch, events=events)
    await sup.maybe_transition("monero", "monerod", True, True)
    host_result(tmp_path, "monero", "failed")
    assert await sup.maybe_transition("monero", "monerod", True, True) is True
    assert (tmp_path / "monero.synced").exists()
    assert not (tmp_path / "monero.synced.tor").exists()
    dc.stop.assert_not_called()
    assert events == [("monero", False)]
    assert await sup.maybe_transition("monero", "monerod", True, False) is True
    host_result(tmp_path, "monero")
    assert await sup.maybe_transition("monero", "monerod", True, False) is False
    dc.start.assert_awaited_once()


async def test_pending_marker_recovers_after_dashboard_restart(tmp_path, monkeypatch):
    (tmp_path / "tari.synced").write_text("pending\n")
    sup, dc = make_supervisor(tmp_path, monkeypatch)
    assert await sup.maybe_transition("tari", "tari", True, False) is True
    dc.stop.assert_not_called()
    host_result(tmp_path, "tari")
    assert await sup.maybe_transition("tari", "tari", True, False) is False
    assert (tmp_path / "tari.synced.tor").exists()


async def test_restart_failure_reverifies_before_retry(tmp_path, monkeypatch):
    sup, dc = make_supervisor(tmp_path, monkeypatch, start=False)
    await sup.maybe_transition("monero", "monerod", True, True)
    host_result(tmp_path, "monero")
    assert await sup.maybe_transition("monero", "monerod", True, True) is True
    assert not (tmp_path / "monero.synced.tor").exists()
    dc.start = AsyncMock(return_value=True)
    assert await sup.maybe_transition("monero", "monerod", True, True) is True
    host_result(tmp_path, "monero")
    assert await sup.maybe_transition("monero", "monerod", True, True) is False


async def test_chains_independent(tmp_path, monkeypatch):
    sup, dc = make_supervisor(tmp_path, monkeypatch)
    assert await sup.maybe_transition("monero", "monerod", True, True) is True
    assert await sup.maybe_transition("tari", "tari", True, False) is True
    host_result(tmp_path, "monero")
    assert await sup.maybe_transition("monero", "monerod", True, True) is False
    assert not (tmp_path / "tari.synced").exists()
    dc.stop.assert_awaited_once()


async def test_control_enabled_uses_existing_host_request_channel(tmp_path, monkeypatch):
    sup, dc = make_supervisor(tmp_path, monkeypatch)
    monkeypatch.setattr(config, "DASHBOARD_CONTROL_ENABLED", True)
    monkeypatch.setattr(config, "CONTROL_REQUESTS_DIR", str(tmp_path / "requests"))
    (tmp_path / "requests").mkdir()
    assert await sup.maybe_transition("monero", "monerod", True, True) is True
    request = next((tmp_path / "requests").glob("*.json"))
    data = json.loads(request.read_text())
    assert data == {
        "id": data["id"],
        "action": "egress-sync",
        "actor": "sync-supervisor",
        "chain": "monero",
    }
    (tmp_path / "results" / request.name).write_text(
        json.dumps({"status": "applied", "chain": "monero"})
    )
    assert await sup.maybe_transition("monero", "monerod", True, True) is False
    dc.start.assert_awaited_once()


async def test_marker_write_failure_keeps_node_clearnet_and_does_not_request(tmp_path, monkeypatch):
    sup, dc = make_supervisor(tmp_path, monkeypatch)
    (tmp_path / "monero.synced").mkdir()
    assert await sup.maybe_transition("monero", "monerod", True, True) is True
    assert not (tmp_path / "requests").exists()
    dc.stop.assert_not_called()


async def test_wrong_chain_result_cannot_authorize_restart(tmp_path, monkeypatch):
    sup, dc = make_supervisor(tmp_path, monkeypatch)
    await sup.maybe_transition("monero", "monerod", True, True)
    request = next((tmp_path / "requests").glob("*.json"))
    (tmp_path / "results" / request.name).write_text(
        json.dumps({"status": "applied", "chain": "tari"})
    )
    assert await sup.maybe_transition("monero", "monerod", True, True) is True
    dc.stop.assert_not_called()
    assert (tmp_path / "monero.synced").exists()


async def test_completion_marker_failure_is_retried_after_restart(tmp_path, monkeypatch):
    sup, dc = make_supervisor(tmp_path, monkeypatch)
    await sup.maybe_transition("monero", "monerod", True, True)
    (tmp_path / "monero.synced.tor").mkdir()
    host_result(tmp_path, "monero")
    assert await sup.maybe_transition("monero", "monerod", True, True) is True
    dc.start.assert_awaited_once()
    assert await sup.maybe_transition("monero", "monerod", True, True) is True
    restarted, _ = make_supervisor(tmp_path, monkeypatch)
    assert await restarted.maybe_transition("monero", "monerod", True, False) is True
