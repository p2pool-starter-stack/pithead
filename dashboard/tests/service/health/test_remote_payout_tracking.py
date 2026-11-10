import asyncio
from unittest.mock import AsyncMock, MagicMock

import pytest

from mining_dashboard.client.monero.monero_wallet_client import MoneroWalletClient
from mining_dashboard.service.health.node_health import NodeHealthMonitor
from mining_dashboard.service.payout_sync import SCAN_LAG_BLOCKS, observe_wallet, remote_tracking

SYNCED = {"reachable": True, "is_syncing": False, "height": 3_000_000}


@pytest.mark.parametrize(
    ("reachable", "scan_answered", "wallet_height", "node", "reason"),
    [
        (True, True, 3_000_000, {"reachable": False}, "the remote node is unreachable"),
        (True, True, 3_000_000, {}, "the remote node has not been read yet"),
        (True, True, 3_000_000, None, "the remote node has not been read yet"),
        (
            True,
            True,
            3_000_000,
            {"reachable": True, "is_syncing": True, "current": 10, "target": 20},
            "the remote node is still syncing",
        ),
        (False, None, None, SYNCED, "the payout wallet is not answering"),
        (True, False, 3_000_000, SYNCED, "the payout scan failed"),
        (True, True, None, SYNCED, "the wallet height is unavailable"),
        (
            True,
            True,
            3_000_000,
            {"reachable": True, "is_syncing": False},
            "the remote node height is unavailable",
        ),
        (
            True,
            True,
            2_999_000,
            SYNCED,
            "the wallet has scanned 2999000 of 3000000 blocks",
        ),
    ],
)
def test_remote_tracking_is_incomplete_with_a_reason(
    reachable, scan_answered, wallet_height, node, reason
):
    assert remote_tracking(reachable, scan_answered, wallet_height, node) == {
        "complete": False,
        "reason": reason,
    }


@pytest.mark.parametrize("lag", [0, 1, SCAN_LAG_BLOCKS])
def test_remote_tracking_is_complete_within_the_scan_lag(lag):
    assert remote_tracking(True, True, 3_000_000 - lag, SYNCED) == {
        "complete": True,
        "reason": None,
    }


def _status(client, node, scan_answered=True):
    monitor = NodeHealthMonitor(down_after=90, clock=lambda: 0, ever_up=True)
    alerts = MagicMock(payout_wallet_down_alert=AsyncMock())
    return asyncio.run(
        observe_wallet("monero", client, monitor, "expected", None, alerts, scan_answered, node)
    )


def test_unreachable_remote_node_marks_tracking_incomplete_with_the_reason():
    client = MagicMock(height=MagicMock(return_value=3_000_000))
    client.payout_addresses.return_value = ["expected"]
    status = _status(client, {"reachable": False})
    assert status["tracking"] == {"complete": False, "reason": "the remote node is unreachable"}


def test_lagging_remote_scan_marks_tracking_incomplete_with_the_reason():
    client = MagicMock(height=MagicMock(return_value=100))
    client.payout_addresses.return_value = ["expected"]
    status = _status(client, SYNCED)
    assert status["reachable"] is True
    assert status["tracking"]["complete"] is False
    assert "scanned 100 of 3000000" in status["tracking"]["reason"]


def test_caught_up_remote_scan_is_complete():
    client = MagicMock(height=MagicMock(return_value=3_000_000))
    client.payout_addresses.return_value = ["expected"]
    assert _status(client, SYNCED)["tracking"] == {"complete": True, "reason": None}


def test_silent_wallet_is_not_asked_for_its_height():
    client = MagicMock()
    client.payout_addresses.return_value = None
    status = _status(client, SYNCED)
    client.height.assert_not_called()
    assert status["tracking"]["reason"] == "the payout wallet is not answering"


def test_local_node_status_carries_no_tracking_verdict():
    client = MagicMock()
    client.payout_addresses.return_value = ["expected"]
    assert "tracking" not in _status(client, None)
    client.height.assert_not_called()


@pytest.mark.parametrize(
    ("result", "expected"),
    [
        ({"height": 42}, 42),
        ({"height": 0}, 0),
        ({"height": -1}, None),
        ({"height": "7"}, None),
        ({}, None),
        (None, None),
    ],
)
def test_wallet_height_accepts_only_non_negative_integers(result, expected):
    client = MoneroWalletClient(url="http://wallet.invalid/json_rpc")
    client._rpc = MagicMock(return_value=result)
    assert client.height() == expected
