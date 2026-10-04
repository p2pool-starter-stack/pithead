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
    assert marker.exists() is not released
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


async def test_tari_only_still_waits_for_monero_across_restart(tmp_path, monkeypatch):
    marker = tmp_path / "sync-gate-reset"
    marker.write_text("tari-only\n")
    monkeypatch.setattr(ds_mod, "SYNC_GATE_RESET_PATH", str(marker))
    svc = service({"miner_released": True})
    await _Loop()._iterate(svc, TARI_SYNCING, monero_sync={"reachable": True, "is_syncing": True})
    assert not svc.miner_released
    restarted = _restored(svc.state_manager)
    await _Loop()._iterate(restarted, TARI_SYNCING, monero_sync=MONERO_SYNCED)
    assert restarted.miner_released
    restarted.docker_control.stop.assert_not_awaited()
    assert not marker.exists()


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
