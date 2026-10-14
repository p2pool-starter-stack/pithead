from unittest.mock import AsyncMock, MagicMock

import pytest

from mining_dashboard.client.tari.generated import base_node_pb2 as bn
from mining_dashboard.client.tari.tari_client import TariClient


def _client_with_stub():
    client = TariClient()
    stub = MagicMock()
    stub.GetNetworkState = AsyncMock(side_effect=RuntimeError("unavailable"))
    client._channel = MagicMock()
    client._channel.close = AsyncMock()
    client._stub = stub  # _ensure_channel returns this since _channel is set
    return client, stub


def _tip(height, synced):
    tip = MagicMock()
    tip.metadata.best_block_height = height
    tip.initial_sync_achieved = synced
    return tip


def _progress(local, target):
    p = MagicMock()
    p.local_height = local
    p.tip_height = target
    return p


class TestFetchSyncStatus:
    async def test_fully_synced(self):
        client, stub = _client_with_stub()
        stub.GetTipInfo = AsyncMock(return_value=_tip(500, synced=True))
        status = await client.get_sync_status()
        assert status == {
            "is_syncing": False,
            "current": 500,
            "target": 500,
            "percent": 100,
            "reachable": True,
        }

    async def test_syncing_with_target(self):
        client, stub = _client_with_stub()
        stub.GetTipInfo = AsyncMock(return_value=_tip(100, synced=False))
        stub.GetSyncProgress = AsyncMock(return_value=_progress(100, 200))
        status = await client.get_sync_status()
        assert status == {
            "is_syncing": True,
            "current": 100,
            "target": 200,
            "percent": 50,
            "reachable": True,
        }

    async def test_syncing_without_reliable_target(self):
        client, stub = _client_with_stub()
        stub.GetTipInfo = AsyncMock(return_value=_tip(100, synced=False))
        stub.GetSyncProgress = AsyncMock(return_value=_progress(100, 100))  # target <= local
        status = await client.get_sync_status()
        assert status == {
            "is_syncing": True,
            "current": 100,
            "target": 0,
            "percent": 0,
            "reachable": True,
        }

    async def test_grpc_error_returns_default_when_no_cache(self):
        client, stub = _client_with_stub()
        stub.GetTipInfo = AsyncMock(side_effect=RuntimeError("unavailable"))
        # Unreachable with no cache: default status, flagged not reachable (Issue #31).
        assert await client.get_sync_status() == {"is_syncing": False, "reachable": False}


class TestCaching:
    async def test_serves_last_known_state_on_transient_failure(self):
        client, stub = _client_with_stub()
        # First call succeeds and populates the cache.
        stub.GetTipInfo = AsyncMock(return_value=_tip(300, synced=True))
        good = await client.get_sync_status()
        assert good["reachable"] is True
        # Next call fails -> cached good reading (within the stale window), but flagged
        # not reachable this cycle so the down-detector still sees the outage.
        stub.GetTipInfo = AsyncMock(side_effect=RuntimeError("busy"))
        cached = await client.get_sync_status()
        assert cached == {**good, "reachable": False}

    async def test_stale_cache_expires(self, monkeypatch):
        client, stub = _client_with_stub()
        stub.GetTipInfo = AsyncMock(return_value=_tip(300, synced=True))
        await client.get_sync_status()
        # Push the cache timestamp beyond the stale window.
        client._last_sync_ts -= client._MAX_STALE_SECONDS + 1
        stub.GetTipInfo = AsyncMock(side_effect=RuntimeError("down"))
        assert await client.get_sync_status() == {"is_syncing": False, "reachable": False}


class TestClose:
    async def test_close_closes_channel(self):
        client, stub = _client_with_stub()
        chan = client._channel
        await client.close()
        chan.close.assert_awaited_once()
        assert client._channel is None


@pytest.mark.parametrize("state", [0, 1, 10, 20, 21, 22, 32, 34])
async def test_live_startup_readiness_is_reachable_and_syncing(state):
    client, stub = _client_with_stub()
    reply = bn.GetNetworkStateResponse()
    reply.readiness_status.state = state
    stub.GetTipInfo = AsyncMock(side_effect=RuntimeError("initializing"))
    stub.GetNetworkState = AsyncMock(return_value=reply)
    status = await client.get_sync_status()
    assert status == {
        "is_syncing": True,
        "initializing": "starting",
        "percent": 0,
        "reachable": True,
    }


async def test_live_migration_overrides_cached_synced_state():
    client, stub = _client_with_stub()
    client._last_sync_status = {"is_syncing": False, "current": 500}
    reply = bn.GetNetworkStateResponse()
    reply.readiness_status.migration.current_block = 250
    reply.readiness_status.migration.total_blocks = 500
    stub.GetTipInfo = AsyncMock(side_effect=RuntimeError("initializing"))
    stub.GetNetworkState = AsyncMock(return_value=reply)
    assert (await client.get_sync_status())["initializing"] == "migrating"


@pytest.mark.parametrize("state", [None, 100, 99])
async def test_absent_ready_or_unknown_readiness_cannot_mask_tip_rpc_failure(state):
    client, stub = _client_with_stub()
    reply = bn.GetNetworkStateResponse()
    if state is not None:
        reply.readiness_status.state = state
    stub.GetTipInfo = AsyncMock(side_effect=RuntimeError("down"))
    stub.GetNetworkState = AsyncMock(return_value=reply)
    assert await client.get_sync_status() == {"is_syncing": False, "reachable": False}


async def test_channel_creation_failure_is_unreachable():
    client = TariClient()
    client._ensure_channel = MagicMock(side_effect=RuntimeError("channel unavailable"))
    client._fetch_initializing_status = AsyncMock()
    assert await client.get_sync_status() == {"is_syncing": False, "reachable": False}
    client._fetch_initializing_status.assert_not_awaited()
