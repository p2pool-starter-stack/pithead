import pathlib
import sys

_HERE = pathlib.Path(__file__).resolve().parent
sys.path.insert(0, str(_HERE.parents[2] / "dashboard"))
sys.path.insert(0, str(_HERE))

from fake_wallet_rpc import FakeWalletRpc  # noqa: E402

from mining_dashboard.client.monero.monero_wallet_client import MoneroWalletClient  # noqa: E402


def test_subaddress_payouts_select_the_resolved_account_and_index():
    primary = "4" + "a" * 94
    subaddress = "8" + "b" * 94
    rows = [
        {"txid": "primary", "amount": 1, "height": 20, "subaddr_index": {"major": 0, "minor": 0}},
        {"txid": "selected", "amount": 2, "height": 20, "subaddr_index": {"major": 2, "minor": 7}},
        {"txid": "other", "amount": 3, "height": 20, "subaddr_index": {"major": 2, "minor": 8}},
        {"txid": "old", "amount": 4, "height": 5, "subaddr_index": {"major": 2, "minor": 7}},
    ]
    for row in rows:
        row["type"] = "block"
    rows.append(
        {
            "txid": "ordinary",
            "amount": 5,
            "height": 20,
            "type": "in",
            "subaddr_index": {"major": 2, "minor": 7},
        }
    )
    with FakeWalletRpc(transfers=rows) as wallet:
        wallet.state["address"] = primary
        wallet.state["subaddresses"] = {subaddress: {"major": 2, "minor": 7}}
        client = MoneroWalletClient(
            url=wallet.url, username="", wallet_address=primary, subaddress=subaddress
        )
        payouts, answered = client.scan(min_height=10)
        assert answered
        assert [row["txid"] for row in payouts] == ["selected"]
        assert client.payout_addresses() == [primary, subaddress]


def test_unknown_subaddress_does_not_report_an_empty_successful_scan():
    with FakeWalletRpc() as wallet:
        client = MoneroWalletClient(
            url=wallet.url,
            username="",
            wallet_address=wallet.state["address"],
            subaddress="8" + "c" * 94,
        )
        assert client.scan() == ([], False)
        assert client.payout_addresses() is None
