import asyncio
from unittest.mock import AsyncMock, MagicMock

import pytest

from mining_dashboard.service.health.node_health import NodeHealthMonitor
from mining_dashboard.service.notify.alert_service import AlertService
from mining_dashboard.service.payout_sync import DOWN_ALERT_ATTEMPTS, observe_wallet


def test_wallet_unreachable_debounces_and_alerts_once():
    for chain in ("monero", "tari"):
        now = [0]
        monitor = NodeHealthMonitor(
            down_after=4, recovery_after=0, clock=lambda now=now: now[0], ever_up=True
        )
        client = MagicMock()
        client.payout_addresses.return_value = None
        if chain == "tari":
            client.payout_addresses = AsyncMock(return_value=(None, None))
        alerts = MagicMock(payout_wallet_down_alert=AsyncMock())

        first = asyncio.run(observe_wallet(chain, client, monitor, "expected", None, alerts))
        assert first["reachable"] is False and first["down"] is False
        now[0] = 3
        pending = asyncio.run(observe_wallet(chain, client, monitor, "expected", first, alerts))
        assert pending["down"] is False
        now[0] = 4
        down = asyncio.run(observe_wallet(chain, client, monitor, "expected", pending, alerts))
        assert down["down"] is True and down["since"] == first["since"]
        asyncio.run(observe_wallet(chain, client, monitor, "expected", down, alerts))
        alerts.payout_wallet_down_alert.assert_awaited_once_with(chain, "unreachable")


def test_address_mismatch_is_explicit_even_before_debounce():
    now = [0]
    monitor = NodeHealthMonitor(down_after=90, clock=lambda: now[0], ever_up=True)
    client = MagicMock(payout_addresses=AsyncMock(return_value=(["wrong", "wrong-emoji"], False)))
    alerts = MagicMock(payout_wallet_down_alert=AsyncMock())

    first = asyncio.run(observe_wallet("tari", client, monitor, "expected", None, alerts))
    assert first["reachable"] is True
    assert first["address_match"] is False
    assert first["configured_address"] == "expected"
    assert first["wallet_address"] == "wrong"
    now[0] = 90
    asyncio.run(observe_wallet("tari", client, monitor, "expected", first, alerts))
    alerts.payout_wallet_down_alert.assert_awaited_once_with(
        "tari", "address differs from configured payout address"
    )


def test_failed_scan_is_unreachable_even_when_address_rpc_answers():
    now = [0]
    monitor = NodeHealthMonitor(down_after=90, clock=lambda: now[0], ever_up=True)
    client = MagicMock()
    client.payout_addresses.return_value = ["expected"]
    alerts = MagicMock(payout_wallet_down_alert=AsyncMock())
    first = asyncio.run(observe_wallet("monero", client, monitor, "expected", None, alerts, False))
    assert first["reachable"] is False and first["address_match"] is True
    now[0] = 90
    down = asyncio.run(observe_wallet("monero", client, monitor, "expected", first, alerts, False))
    assert down["down"] is True
    alerts.payout_wallet_down_alert.assert_awaited_once_with("monero", "unreachable")


def test_wallet_down_event_has_no_event_specific_opt_out():
    sink = MagicMock(enabled=True)
    sink.event_enabled.return_value = False
    service = AlertService(sinks=[sink])
    asyncio.run(service.payout_wallet_down_alert("monero", "unreachable"))
    sink.send.assert_called_once()
    assert sink.send.call_args.args[1] == "payout_wallet_down"
    sink.enabled = False
    asyncio.run(service.payout_wallet_down_alert("tari", "unreachable"))
    sink.send.assert_called_once()


def _down_after_one_cycle():
    now = [0]
    monitor = NodeHealthMonitor(down_after=1, clock=lambda: now[0], ever_up=True)
    client = MagicMock()
    client.payout_addresses.return_value = None
    first = asyncio.run(observe_wallet("monero", client, monitor, "expected", None, MagicMock()))
    now[0] = 1
    return client, monitor, first


def test_raising_down_alert_keeps_status_and_retries_the_edge():
    client, monitor, first = _down_after_one_cycle()
    alerts = MagicMock(payout_wallet_down_alert=AsyncMock(side_effect=[RuntimeError("sink"), None]))
    down = asyncio.run(observe_wallet("monero", client, monitor, "expected", first, alerts))
    assert down["down"] is True and down["reachable"] is False
    assert down["down_alert_failures"] == 1
    retried = asyncio.run(observe_wallet("monero", client, monitor, "expected", down, alerts))
    assert retried["down_alert_failures"] == 0
    asyncio.run(observe_wallet("monero", client, monitor, "expected", retried, alerts))
    assert alerts.payout_wallet_down_alert.await_count == 2


def test_raising_down_alert_stops_after_bounded_attempts():
    client, monitor, status = _down_after_one_cycle()
    alerts = MagicMock(payout_wallet_down_alert=AsyncMock(side_effect=RuntimeError("sink")))
    for _ in range(DOWN_ALERT_ATTEMPTS + 2):
        status = asyncio.run(observe_wallet("monero", client, monitor, "expected", status, alerts))
        assert status["down"] is True
    assert alerts.payout_wallet_down_alert.await_count == DOWN_ALERT_ATTEMPTS


@pytest.mark.parametrize("chain", ["monero", "tari"])
def test_recovery_keeps_outage_time_without_retrying_a_resolved_failure(chain):
    now = [0]
    monitor = NodeHealthMonitor(down_after=1, recovery_after=4, clock=lambda: now[0], ever_up=True)
    client = MagicMock()
    client.payout_addresses.return_value = None
    if chain == "tari":
        client.payout_addresses = AsyncMock(return_value=(None, None))
    alerts = MagicMock(payout_wallet_down_alert=AsyncMock(side_effect=RuntimeError("sink")))
    first = asyncio.run(observe_wallet(chain, client, monitor, "expected", None, alerts))
    now[0] = 1
    down = asyncio.run(observe_wallet(chain, client, monitor, "expected", first, alerts))
    assert down["down_alert_failures"] == 1

    client.payout_addresses.return_value = (["expected"], True) if chain == "tari" else ["expected"]
    now[0] = 2
    recovering = asyncio.run(observe_wallet(chain, client, monitor, "expected", down, alerts))
    assert recovering["reachable"] is True and recovering["address_match"] is True
    assert recovering["down"] is True
    assert recovering["since"] == first["since"]
    alerts.payout_wallet_down_alert.assert_awaited_once_with(chain, "unreachable")

    now[0] = 6
    recovered = asyncio.run(observe_wallet(chain, client, monitor, "expected", recovering, alerts))
    assert recovered["down"] is False and recovered["since"] is None
    assert recovered["down_alert_failures"] == 0
    alerts.payout_wallet_down_alert.assert_awaited_once_with(chain, "unreachable")
