import asyncio
from unittest.mock import AsyncMock, MagicMock

from mining_dashboard.service.health.node_health import NodeHealthMonitor
from mining_dashboard.service.notify.alert_service import AlertService
from mining_dashboard.service.payout_sync import observe_wallet


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
