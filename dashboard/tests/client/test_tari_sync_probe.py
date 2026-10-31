from unittest.mock import AsyncMock

from mining_dashboard.client.tari.generated import base_node_pb2 as bn
from mining_dashboard.client.tari.tari_client import TariClient


async def test_real_tip_response_exposes_wait_reason_and_clears_probe_error():
    client = TariClient()
    stub = AsyncMock()
    client._channel = AsyncMock()
    client._stub = stub
    stub.GetTipInfo.return_value = bn.TipInfoResponse(
        metadata=bn.MetaData(best_block_height=100),
        initial_sync_achieved=False,
        base_node_state=bn.HEADER_SYNC,
    )
    stub.GetSyncProgress.return_value = bn.SyncProgressResponse(
        local_height=100,
        tip_height=200,
        state=bn.HEADER,
    )
    status = await client.get_sync_status()
    assert status["is_syncing"] is True
    assert client.sync_probe == {
        "initial_sync_achieved": False,
        "base_node_state": "HEADER_SYNC",
        "sync_state": "HEADER",
    }
    stub.GetSyncProgress.side_effect = RuntimeError("private details")
    await client.get_sync_status()
    assert client.sync_probe["error"] == "GetSyncProgress probe failed"
    client._channel, client._stub = AsyncMock(), stub
    stub.GetTipInfo.side_effect = RuntimeError("private details")
    stub.GetNetworkState.side_effect = RuntimeError("not ready")
    status = await client.get_sync_status()
    assert status["reachable"] is False
    assert client.sync_probe == {"error": "GetTipInfo probe failed"}
    client._channel, client._stub = AsyncMock(), stub
    stub.GetTipInfo.side_effect = None
    stub.GetTipInfo.return_value.initial_sync_achieved = True
    await client.get_sync_status()
    assert client.sync_probe["initial_sync_achieved"] is True
    assert "error" not in client.sync_probe
