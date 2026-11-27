"""Tari-only apply resets never revoke a machine's earned Monero release."""

import os
from unittest.mock import AsyncMock, MagicMock

import pytest

from tests.service._data_service_support import DataService, ds_mod
from tests.service.test_data_service_sync_gate import (
    TestSyncGateDecision as _Loop,
)
from tests.service.test_data_service_sync_gate import (
    _restored,
)

MONERO_SYNCED = {"is_syncing": False, "reachable": True, "synchronized": True}
TARI_SYNCING = {"is_syncing": True, "reachable": True, "current": 1, "target": 100}


def service(snapshot):
    state = MagicMock()
    state.load_snapshot.return_value = snapshot
    svc = DataService(state, MagicMock(), MagicMock())
    svc.docker_control.start = AsyncMock(return_value=True)
    svc.docker_control.stop = AsyncMock(return_value=True)
    return svc


@pytest.mark.parametrize(
    ("marker_text", "earned", "released"),
    [
        ("tari-only\n", True, True),
        ("", True, False),
        ("tari-only\n", False, False),
        ("unknown\n", True, False),
    ],
)
async def test_tari_rearm_requires_an_earned_release(
    tmp_path, monkeypatch, marker_text, earned, released
):
    marker = tmp_path / "sync-gate-reset"
    marker.write_text(marker_text)
    monkeypatch.setattr(ds_mod, "SYNC_GATE_RESET_PATH", str(marker))
    svc = service({"miner_released": earned})
    await _Loop()._iterate(svc, TARI_SYNCING, monero_sync=MONERO_SYNCED, network_height=800000)
    assert svc.miner_released is released
    assert marker.exists()  # typed policy survives until a full reset replaces it
    if released:
        svc.docker_control.stop.assert_not_awaited()
        assert svc.latest_data["tari_syncing_passive"] is True
        assert svc.latest_data["global_sync"] is False
        restarted = _restored(svc.state_manager)
        await _Loop()._iterate(
            restarted, TARI_SYNCING, monero_sync=MONERO_SYNCED, network_height=800000
        )
        restarted.docker_control.stop.assert_not_awaited()
        assert restarted.latest_data["tari_syncing_passive"] is True
    else:
        assert {call.args[0] for call in svc.docker_control.stop.await_args_list} == {
            "p2pool",
            "xmrig-proxy",
        }
        svc.docker_control.start.assert_not_awaited()


async def test_first_install_waits_for_tari(tmp_path, monkeypatch):
    monkeypatch.setattr(ds_mod, "SYNC_GATE_RESET_PATH", str(tmp_path / "absent"))
    svc = service(None)
    await _Loop()._iterate(svc, TARI_SYNCING, monero_sync=MONERO_SYNCED)
    assert svc.miner_released is False
    svc.docker_control.start.assert_not_awaited()
    assert {call.args[0] for call in svc.docker_control.stop.await_args_list} == {
        "p2pool",
        "xmrig-proxy",
    }


@pytest.mark.parametrize(
    "monero_sample", [{"reachable": False}, {"reachable": True, "is_syncing": True}]
)
async def test_tari_only_preserves_release_through_monero_startup_and_restart(
    tmp_path, monkeypatch, monero_sample
):
    marker = tmp_path / "sync-gate-reset"
    marker.write_text("tari-only\n")
    monkeypatch.setattr(ds_mod, "SYNC_GATE_RESET_PATH", str(marker))
    svc = service({"miner_released": True})
    assert svc.miner_released
    await _Loop()._iterate(svc, TARI_SYNCING, monero_sync=monero_sample)
    assert svc.miner_released
    svc.docker_control.stop.assert_not_awaited()
    svc.docker_control.start.assert_not_awaited()
    restarted = _restored(svc.state_manager)
    await _Loop()._iterate(restarted, TARI_SYNCING, monero_sync=monero_sample)
    assert restarted.miner_released
    restarted.docker_control.stop.assert_not_awaited()
    assert marker.exists()


async def test_tari_only_cold_monero_outage_uses_worker_failover(tmp_path, monkeypatch):
    marker = tmp_path / "sync-gate-reset"
    marker.write_text("tari-only\n")
    monkeypatch.setattr(ds_mod, "SYNC_GATE_RESET_PATH", str(marker))
    svc = service({"miner_released": True})
    now = [0]
    svc.monero_health._clock = svc.tari_health._clock = lambda: now[0]
    for tick in (0, 89):
        now[0] = tick
        await _Loop()._iterate(svc, TARI_SYNCING, monero_sync={"reachable": False})
        assert svc.miner_released
        assert not svc.workers_rejected
        svc.docker_control.stop.assert_not_awaited()
    now[0] = 90
    await _Loop()._iterate(svc, TARI_SYNCING, monero_sync={"reachable": False})
    assert svc.miner_released
    assert svc.workers_rejected
    svc.docker_control.stop.assert_awaited_once_with("xmrig-proxy")
    for tick in (91, 152):
        now[0] = tick
        await _Loop()._iterate(svc, TARI_SYNCING, monero_sync=MONERO_SYNCED)
    assert svc.miner_released
    assert not svc.workers_rejected
    svc.docker_control.start.assert_awaited_once_with("xmrig-proxy")


@pytest.mark.parametrize("kind", ["symlink", "dangling", "fifo", "directory"])
def test_nonregular_marker_cannot_relax_the_hold(tmp_path, monkeypatch, kind):
    marker = tmp_path / "sync-gate-reset"
    if kind == "symlink":
        target = tmp_path / "target"
        target.write_text("tari-only\n")
        marker.symlink_to(target)
    elif kind == "dangling":
        marker.symlink_to(tmp_path / "absent")
    elif kind == "fifo":
        os.mkfifo(marker)
    else:
        marker.mkdir()
    monkeypatch.setattr(ds_mod, "SYNC_GATE_RESET_PATH", str(marker))
    svc = service({"miner_released": True, "sync_gate_monero_only": True})
    assert not svc.miner_released
    assert not svc.sync_gate_monero_only


def test_full_reset_revokes_background_policy(tmp_path, monkeypatch):
    marker = tmp_path / "sync-gate-reset"
    marker.touch()
    monkeypatch.setattr(ds_mod, "SYNC_GATE_RESET_PATH", str(marker))
    svc = service({"miner_released": True, "sync_gate_monero_only": True})
    assert not svc.sync_gate_monero_only


@pytest.mark.parametrize("phase", ["starting", "migrating", "syncing"])
async def test_earned_tari_rearm_preserves_required_node_failover(tmp_path, monkeypatch, phase):
    marker = tmp_path / "sync-gate-reset"
    marker.write_text("tari-only\n")
    monkeypatch.setattr(ds_mod, "SYNC_GATE_RESET_PATH", str(marker))
    svc = service({"miner_released": True})
    now = [0]
    svc.tari_health._clock = svc.monero_health._clock = lambda: now[0]
    progress = dict(TARI_SYNCING)
    if phase != "syncing":
        progress["initializing"] = phase
    for tick in (0, 901, 9600):
        now[0] = tick
        await _Loop()._iterate(svc, progress, monero_sync=MONERO_SYNCED)
        assert svc.miner_released
        assert not svc.workers_rejected
        svc.docker_control.stop.assert_not_awaited()

    # The background sync exemption never disables #3091's unreachable-RPC policy.
    for tick in (9601, 10501):
        now[0] = tick
        await _Loop()._iterate(svc, {"reachable": False}, monero_sync=MONERO_SYNCED)
    assert svc.workers_rejected
    svc.docker_control.stop.assert_awaited_once_with("xmrig-proxy")
    svc.docker_control.start.reset_mock()
    for tick in (10600, 10661):
        now[0] = tick
        await _Loop()._iterate(svc, progress, monero_sync=MONERO_SYNCED)
    assert not svc.workers_rejected
    svc.docker_control.start.assert_awaited_once_with("xmrig-proxy")
