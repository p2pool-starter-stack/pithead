import asyncio
from unittest.mock import AsyncMock, MagicMock, patch

from mining_dashboard.service.health.node_health import NodeHealthMonitor
from mining_dashboard.service.notify.alert_service import AlertService
from mining_dashboard.service.payout_sync import (
    observe_enabled_wallets,
    observed_monero_pair,
    sync_monero,
)

PRIMARY = "4" + "A" * 94
SUBADDRESS = "8" + "B" * 94
OTHER_SUBADDRESS = "8" + "C" * 94


def test_wallet_health_uses_effective_subaddress_and_requires_pair():
    service = MagicMock()
    service.latest_data = {}
    service.wallet_client.payout_addresses.return_value = [PRIMARY, SUBADDRESS]
    service.monero_wallet_health = NodeHealthMonitor(down_after=0, recovery_after=0)
    service.monero_wallet_scan_answered = True
    service.tari_wallet_client = None
    service.alert_service.payout_wallet_down_alert = AsyncMock()

    with patch("mining_dashboard.service.payout_sync.MONERO_PAYOUT_ADDRESS", SUBADDRESS):
        asyncio.run(observe_enabled_wallets(service))

    assert service.latest_data["payout_wallet"]["monero"]["address_match"] is True


def test_payout_alert_receives_effective_subaddress():
    manager = MagicMock()
    manager.get_payout_max_height.return_value = 0
    manager.add_payouts.return_value = [{"txid": "tx", "height": 1, "amount_atomic": 1}]
    client = MagicMock()
    client.scan.return_value = ([{"txid": "tx"}], True)
    alerts = MagicMock(payout_confirmed_alert=AsyncMock())

    with (
        patch("mining_dashboard.service.payout_sync.MONERO_PAYOUT_ADDRESS", SUBADDRESS),
        patch("mining_dashboard.config.config.MONERO_WALLET_ADDRESS", PRIMARY),
    ):
        asyncio.run(sync_monero(manager, client, alerts))

    alerts.payout_confirmed_alert.assert_awaited_once_with("monero", 1, "tx", SUBADDRESS)


def test_pair_tripwire_rebaselines_only_after_either_address_changes():
    store = {}
    service = AlertService(
        sinks=[MagicMock(enabled=True, event_enabled=lambda _event: True)],
        kv_get=store.get,
        kv_set=lambda key, value: store.__setitem__(key, str(value)),
    )

    assert service._wallet_edges((PRIMARY, SUBADDRESS)) == []
    assert store["payout_wallet"] == PRIMARY
    assert store["payout_subaddress"] == SUBADDRESS
    assert service._wallet_edges((PRIMARY, SUBADDRESS)) == []

    alerts = service._wallet_edges((PRIMARY, OTHER_SUBADDRESS))
    assert [event for event, _text in alerts] == [AlertService.EVT_WALLET_CHANGED]
    assert store["payout_wallet"] == PRIMARY
    assert store["payout_subaddress"] == OTHER_SUBADDRESS
    assert store["payout_wallet_new8"] == OTHER_SUBADDRESS[:8]
    assert SUBADDRESS[:8] in alerts[0][1]
    assert OTHER_SUBADDRESS[:8] in alerts[0][1]
    assert SUBADDRESS not in alerts[0][1]


def test_stratum_effective_destination_maps_to_the_runtime_pair():
    with (
        patch("mining_dashboard.service.payout_sync.MONERO_WALLET_ADDRESS", PRIMARY),
        patch("mining_dashboard.service.payout_sync.MONERO_SUBADDRESS", SUBADDRESS),
    ):
        assert observed_monero_pair(SUBADDRESS) == (PRIMARY, SUBADDRESS)
        assert observed_monero_pair(PRIMARY) == (PRIMARY, "")
        assert observed_monero_pair("") == (PRIMARY, SUBADDRESS)
        assert observed_monero_pair("Unknown") == ("Unknown", "")


def test_existing_primary_baseline_treats_first_subaddress_as_a_change():
    store = {"payout_wallet": PRIMARY}
    service = AlertService(
        sinks=[MagicMock(enabled=True, event_enabled=lambda _event: True)],
        kv_get=store.get,
        kv_set=lambda key, value: store.__setitem__(key, str(value)),
    )

    alerts = service._wallet_edges((PRIMARY, SUBADDRESS))
    assert [event for event, _text in alerts] == [AlertService.EVT_WALLET_CHANGED]
    assert store["payout_subaddress"] == SUBADDRESS


def test_confirmed_payout_alert_names_effective_address_without_full_value():
    sink = MagicMock(enabled=True, event_enabled=lambda _event: True)
    service = AlertService(sinks=[sink])

    text = asyncio.run(service.payout_confirmed_alert("monero", 1, "tx", SUBADDRESS))

    assert SUBADDRESS[:8] in text
    assert SUBADDRESS not in text


def test_incoming_payout_alert_names_effective_address_without_full_value():
    service = AlertService(sinks=[MagicMock(enabled=True, event_enabled=lambda _event: True)])
    service._block_edges(1, 1, 1)

    with patch("mining_dashboard.service.notify.alert_edges.MONERO_PAYOUT_ADDRESS", SUBADDRESS):
        alerts = service._block_edges(2, 2, 1)

    text = next(text for event, text in alerts if event == AlertService.EVT_PAYOUT_FOUND)
    assert SUBADDRESS[:8] in text
    assert SUBADDRESS not in text
