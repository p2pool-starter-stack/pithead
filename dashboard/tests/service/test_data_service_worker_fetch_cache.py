"""Failed proxy polls retain workers, but never indefinitely."""

import time
from types import SimpleNamespace
from unittest.mock import AsyncMock, MagicMock, patch

import pytest

import mining_dashboard.service.data_service as ds_mod
from mining_dashboard.service.data_helpers import _normalize_proxy_workers
from mining_dashboard.service.data_service import DataService
from mining_dashboard.service.storage_service import StateManager
from mining_dashboard.web.server import create_app
from tests.service._data_service_support import _FakeClientSession

_GOOD = {"workers": [["pithead", "10.0.0.1", 1, 5, 0, 0, 0, 0, 1, 2, 3, 4, 5]]}


class _PollPublished(BaseException):
    """Stop after publication; an earlier loop error cannot satisfy the test."""


@pytest.fixture
async def cached_service(aiohttp_client):
    sm = StateManager(db_path=":memory:")
    proxy = MagicMock()
    svc = DataService(sm, proxy, MagicMock())
    svc.docker_control = MagicMock()
    svc.docker_control.stop = AsyncMock(return_value=True)
    svc.docker_control.start = AsyncMock(return_value=True)
    svc.tor_healer.check = AsyncMock(side_effect=_PollPublished)
    client = await aiohttp_client(create_app(sm, svc.latest_data))
    yield svc, proxy, client
    sm.close()


async def _poll(svc, proxy, payload, now, direct=None):
    proxy.get_workers.side_effect = payload if isinstance(payload, Exception) else None
    proxy.get_workers.return_value = payload
    worker = MagicMock()
    worker.get_stats = AsyncMock(return_value=direct or {})
    tari = MagicMock()
    tari.get_sync_status = AsyncMock(return_value={"is_syncing": False, "reachable": True})
    with (
        patch.object(ds_mod, "time", SimpleNamespace(time=time.time, monotonic=lambda: now)),
        patch.object(ds_mod, "ClientSession", _FakeClientSession),
        patch.object(ds_mod, "XMRigWorkerClient", return_value=worker),
        patch.object(ds_mod, "TariClient", return_value=tari),
        patch.object(ds_mod, "get_stratum_stats", return_value={}),
        patch.object(ds_mod, "get_network_stats", return_value={"height": 100}),
        patch.object(ds_mod, "get_tari_stats", return_value={"active": False, "height": 0}),
        patch.object(ds_mod, "get_p2pool_stats", return_value={"pool": {}}),
        patch.object(
            ds_mod,
            "get_monero_sync_status",
            AsyncMock(return_value={"is_syncing": False, "reachable": True}),
        ),
        patch.object(ds_mod, "get_disk_usage", return_value={}),
        patch.object(ds_mod, "get_hugepages_status", return_value=("Enabled", "ok", "1/2")),
        patch.object(ds_mod, "get_memory_usage", return_value={}),
        patch.object(ds_mod, "get_load_average", return_value="0"),
        patch.object(ds_mod, "get_cpu_usage", return_value="0%"),
        patch.object(ds_mod, "get_cpu_avx2", return_value=True),
    ):
        with pytest.raises(_PollPublished):
            await svc.run()


async def _online(client):
    resp = await client.get("/api/state")
    assert resp.status == 200
    state = await resp.json()
    return [w["name"] for w in state["workers"] if w["status"] == "online"]


@pytest.mark.parametrize("failure", [OSError("proxy unreachable"), {"error": "bad response"}])
async def test_failed_poll_retains_worker_in_state(cached_service, failure):
    svc, proxy, client = cached_service
    await _poll(svc, proxy, _GOOD, 0)
    assert await _online(client) == ["pithead"]
    await _poll(svc, proxy, failure, 30)
    assert await _online(client) == ["pithead"]


async def test_successful_empty_poll_replaces_cache(cached_service):
    svc, proxy, client = cached_service
    await _poll(svc, proxy, _GOOD, 0)
    await _poll(svc, proxy, {"workers": []}, 30)
    assert await _online(client) == []
    await _poll(svc, proxy, OSError("proxy unreachable"), 60)
    assert await _online(client) == []


async def test_failures_expire_at_five_minutes_and_recovery_resets_cap(cached_service):
    svc, proxy, client = cached_service
    await _poll(svc, proxy, _GOOD, 0)
    for now in (30, 150, 299):
        await _poll(svc, proxy, OSError("proxy unreachable"), now)
        assert await _online(client) == ["pithead"]
    for now in (300, 330):
        await _poll(svc, proxy, OSError("proxy unreachable"), now)
        assert await _online(client) == []
    await _poll(svc, proxy, _GOOD, 360)
    await _poll(svc, proxy, OSError("proxy unreachable"), 600)
    assert await _online(client) == ["pithead"]


async def test_failure_before_any_success_has_no_workers(cached_service):
    svc, proxy, client = cached_service
    await _poll(svc, proxy, OSError("proxy unreachable"), 0)
    assert await _online(client) == []


async def test_cache_is_not_mutated_by_direct_stats_or_lifecycle(cached_service):
    svc, proxy, client = cached_service
    await _poll(
        svc,
        proxy,
        _GOOD,
        0,
        direct={"api_ok": True, "uptime": 999, "hashrate": {"total": [9000, 9000, 9000]}},
    )
    await _poll(svc, proxy, OSError("proxy unreachable"), 30)
    assert await _online(client) == ["pithead"]
    assert svc.latest_data["workers"][0]["h15"] == 2000
    assert svc._last_proxy_workers == _normalize_proxy_workers(_GOOD)
