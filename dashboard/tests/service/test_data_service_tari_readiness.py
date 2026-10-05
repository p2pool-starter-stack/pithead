"""Live progress never becomes a required-Tari outage, even across a long migration."""

from types import SimpleNamespace
from unittest.mock import AsyncMock, MagicMock, patch

import pytest

from mining_dashboard.service import data_service as ds
from mining_dashboard.service.data_service import DataService


@pytest.mark.parametrize("phase", ["starting", "migrating", "syncing"])
@pytest.mark.parametrize("required", [True, False])
async def test_live_progress_never_rejects_but_alerts(phase, required):
    sm = MagicMock()
    sm.load_snapshot.return_value = None
    svc = DataService(sm, MagicMock(), MagicMock())
    svc.docker_control = SimpleNamespace(stop=AsyncMock(), start=AsyncMock())
    svc.tari_chain.explorer_url = ""
    svc.tari_chain._notify = AsyncMock(return_value="sent")
    svc.monero_health.healthy = True
    now = [0]
    svc.tari_health._clock = lambda: now[0]
    svc.tari_health.update(True)
    client = SimpleNamespace(get_connections=AsyncMock(return_value=5))
    sync = {"reachable": True, "is_syncing": True}
    if phase != "syncing":
        sync["initializing"] = phase
    with patch.object(ds, "TARI_REQUIRED", required):
        for time in (0, 900, 9000):
            now[0] = time
            down = await svc._observe_tari(client, sync)
            await svc._apply_worker_rejection(False, down)
            assert down is False
            assert svc.workers_rejected is False
    svc.docker_control.stop.assert_not_awaited()
    svc.tari_chain._notify.assert_awaited_once()
    assert f"node is {phase}" in svc.tari_chain._notify.await_args.args[0]


async def test_cached_sync_reading_cannot_exempt_a_live_rpc_outage():
    sm = MagicMock()
    sm.load_snapshot.return_value = None
    svc = DataService(sm, MagicMock(), MagicMock())
    svc.tari_chain.explorer_url = ""
    svc.tari_chain._notify = None
    svc.tari_health.ever_up = True
    now = [0]
    svc.tari_health._clock = lambda: now[0]
    sync = {"reachable": False, "is_syncing": True, "initializing": "migrating"}
    assert await svc._observe_tari(MagicMock(), sync) is False
    now[0] = 900
    assert await svc._observe_tari(MagicMock(), sync) is True


@pytest.mark.parametrize("initial_required", [True, False])
async def test_never_answered_tari_detects_outage_after_restart_or_policy_change(initial_required):
    from mining_dashboard.service import data_setup
    from mining_dashboard.service.notify.alert_service import AlertService
    from tests.service.notify._alert_service_support import _ev, _svc

    sm = MagicMock()
    sm.load_snapshot.return_value = None
    with patch.object(data_setup, "TARI_MODE", "local"):
        svc = DataService(sm, MagicMock(), MagicMock())
    svc.miner_released = True
    svc.alert_service = _svc()
    svc.docker_control = SimpleNamespace(stop=AsyncMock(return_value=True), start=AsyncMock())
    svc.tari_chain._notify = None
    now = [0]
    svc.tari_health._clock = lambda: now[0]
    sync = {"reachable": False}
    with patch.object(data_setup, "TARI_MODE", "local"):
        assert await svc._observe_tari(MagicMock(), sync) is False
        _ev(svc.alert_service, tari_down=False, tari_required=initial_required)
        now[0] = 899
        assert await svc._observe_tari(MagicMock(), sync) is False
        now[0] = 900
        down = await svc._observe_tari(MagicMock(), sync)
    assert down is True
    with patch.object(ds, "TARI_REQUIRED", initial_required):
        await svc._apply_worker_rejection(False, down)
    assert svc.workers_rejected is initial_required
    alerts = _ev(svc.alert_service, tari_down=down, tari_required=initial_required)
    assert AlertService.EVT_NODE_DOWN in [key for key, _ in alerts]
    with patch.object(ds, "TARI_REQUIRED", True):
        await svc._apply_worker_rejection(False, down)
    assert svc.workers_rejected is True
    svc.docker_control.stop.assert_awaited_once()
    assert svc.monero_health.ever_up is False
