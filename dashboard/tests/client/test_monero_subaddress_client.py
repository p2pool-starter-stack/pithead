from unittest.mock import patch

from mining_dashboard.client.monero.monero_wallet_client import MoneroWalletClient

PRIMARY = "4" + "A" * 94
SUBADDRESS = "8" + "B" * 94


def test_subaddress_scan_resolves_and_filters_exact_index():
    client = MoneroWalletClient(wallet_address=PRIMARY, subaddress=SUBADDRESS)
    calls = []

    def rpc(method, params=None):
        calls.append((method, params))
        if method == "get_address":
            return {"address": PRIMARY}
        if method == "get_address_index":
            return {"index": {"major": 2, "minor": 7}}
        return {"in": []}

    with patch.object(client, "_rpc", side_effect=rpc):
        assert client.scan(123) == ([], True)

    assert calls == [
        ("get_address", None),
        ("get_address_index", {"address": SUBADDRESS}),
        (
            "get_transfers",
            {
                "in": True,
                "coinbase": True,
                "filter_by_height": True,
                "min_height": 123,
                "account_index": 2,
                "subaddr_indices": [7],
            },
        ),
    ]


def test_subaddress_scan_fails_closed_when_index_is_unknown_or_malformed():
    client = MoneroWalletClient(wallet_address=PRIMARY, subaddress=SUBADDRESS)
    for answer in (None, {}, {"index": {}}, {"index": {"major": True, "minor": 1}}):
        with patch.object(client, "_rpc", side_effect=[{"address": PRIMARY}, answer]) as rpc:
            assert client.scan() == ([], False)
            assert rpc.call_args_list[-1].args == (
                "get_address_index",
                {"address": SUBADDRESS},
            )


def test_wallet_health_addresses_require_primary_and_owned_subaddress():
    client = MoneroWalletClient(wallet_address=PRIMARY, subaddress=SUBADDRESS)
    with patch.object(
        client,
        "_rpc",
        side_effect=[
            {"address": PRIMARY},
            {"index": {"major": 0, "minor": 3}},
        ],
    ):
        assert client.payout_addresses() == [PRIMARY, SUBADDRESS]

    with patch.object(client, "_rpc", side_effect=[{"address": PRIMARY}, {}]):
        assert client.payout_addresses() is None


def test_subaddress_scan_fails_closed_when_primary_does_not_match():
    client = MoneroWalletClient(wallet_address=PRIMARY, subaddress=SUBADDRESS)
    with patch.object(client, "_rpc", return_value={"address": "4" + "C" * 94}) as rpc:
        assert client.scan() == ([], False)
    rpc.assert_called_once_with("get_address")


def test_subaddress_scan_ignores_ordinary_incoming_transfers():
    client = MoneroWalletClient(wallet_address=PRIMARY, subaddress=SUBADDRESS)
    rows = [
        {"type": "in", "txid": "ordinary", "amount": 1, "height": 2},
        {"type": "block", "txid": "mined", "amount": 2, "height": 3},
    ]
    with patch.object(
        client,
        "_rpc",
        side_effect=[
            {"address": PRIMARY},
            {"index": {"major": 0, "minor": 1}},
            {"in": rows},
        ],
    ):
        payouts, answered = client.scan()

    assert answered is True
    assert [payout["txid"] for payout in payouts] == ["mined"]


def test_primary_only_scan_keeps_legacy_request_shape():
    client = MoneroWalletClient(wallet_address=PRIMARY, subaddress="")
    with patch.object(client, "_rpc", return_value={"in": []}) as rpc:
        assert client.scan(9) == ([], True)
    assert rpc.call_args.args[0] == "get_transfers"
    assert "account_index" not in rpc.call_args.args[1]
    assert "subaddr_indices" not in rpc.call_args.args[1]
