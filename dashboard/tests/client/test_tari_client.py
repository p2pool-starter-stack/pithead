from unittest.mock import AsyncMock, MagicMock

from mining_dashboard.client.tari.tari_client import TariClient


def _client_with_stub():
    client = TariClient()
    stub = MagicMock()
    client._channel = MagicMock()
    client._channel.close = AsyncMock()
    client._stub = stub  # _ensure_channel returns this since _channel is set
    return client, stub


def _tip(height, synced, base_node_state=1):
    tip = MagicMock()
    tip.metadata.best_block_height = height
    tip.initial_sync_achieved = synced
    tip.base_node_state = base_node_state  # 1 = HEADER_SYNC
    return tip


def _progress(local, target, state=2, short_desc=""):
    p = MagicMock()
    p.local_height = local
    p.tip_height = target
    p.state = state  # 2 = HEADER
    p.short_desc = short_desc
    return p


class TestFetchSyncStatus:
    async def test_fully_synced(self):
        client, stub = _client_with_stub()
        stub.GetTipInfo = AsyncMock(return_value=_tip(500, synced=True, base_node_state=5))
        status = await client.get_sync_status()
        assert status == {
            "is_syncing": False,
            "current": 500,
            "target": 500,
            "percent": 100,
            "initial_sync_achieved": True,
            "base_node_state": "LISTENING",
            "reachable": True,
            "error": None,
        }

    async def test_syncing_with_target(self):
        client, stub = _client_with_stub()
        stub.GetTipInfo = AsyncMock(return_value=_tip(100, synced=False))
        stub.GetSyncProgress = AsyncMock(return_value=_progress(100, 200, short_desc="catching up"))
        status = await client.get_sync_status()
        assert status == {
            "is_syncing": True,
            "current": 100,
            "target": 200,
            "percent": 50,
            "initial_sync_achieved": False,
            "base_node_state": "HEADER_SYNC",
            "sync_state": "HEADER",
            "short_desc": "catching up",
            "reachable": True,
            "error": None,
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
            "initial_sync_achieved": False,
            "base_node_state": "HEADER_SYNC",
            "sync_state": "HEADER",
            "short_desc": None,
            "reachable": True,
            "error": None,
        }

    async def test_grpc_error_returns_default_when_no_cache(self):
        client, stub = _client_with_stub()
        stub.GetTipInfo = AsyncMock(side_effect=RuntimeError("unavailable"))
        # Unreachable with no cache: default status, flagged not reachable (Issue #31), and the
        # probe error carried through for the remote-sync-wait reason (#2353).
        assert await client.get_sync_status() == {
            "is_syncing": False,
            "reachable": False,
            "error": "unavailable",
        }


class TestCaching:
    async def test_serves_last_known_state_on_transient_failure(self):
        client, stub = _client_with_stub()
        # First call succeeds and populates the cache.
        stub.GetTipInfo = AsyncMock(return_value=_tip(300, synced=True))
        good = await client.get_sync_status()
        assert good["reachable"] is True
        # Next call fails -> cached good reading (within the stale window), but flagged
        # not reachable this cycle so the down-detector still sees the outage, and the
        # error is this cycle's, even though the cached data is stale-served (#2353).
        stub.GetTipInfo = AsyncMock(side_effect=RuntimeError("busy"))
        cached = await client.get_sync_status()
        assert cached == {**good, "reachable": False, "error": "busy"}

    async def test_stale_cache_expires(self, monkeypatch):
        client, stub = _client_with_stub()
        stub.GetTipInfo = AsyncMock(return_value=_tip(300, synced=True))
        await client.get_sync_status()
        # Push the cache timestamp beyond the stale window.
        client._last_sync_ts -= client._MAX_STALE_SECONDS + 1
        stub.GetTipInfo = AsyncMock(side_effect=RuntimeError("down"))
        assert await client.get_sync_status() == {
            "is_syncing": False,
            "reachable": False,
            "error": "down",
        }


class TestClose:
    async def test_close_closes_channel(self):
        client, stub = _client_with_stub()
        chan = client._channel
        await client.close()
        chan.close.assert_awaited_once()
        assert client._channel is None
