"""Wallet RPC contract tests split from ``test_contract.py`` for its file budget."""

import pathlib
import sys

_HERE = pathlib.Path(__file__).resolve().parent
_REPO = _HERE.parents[2]
sys.path.insert(0, str(_REPO / "dashboard"))
sys.path.insert(0, str(_HERE))

from fake_wallet_rpc import FakeWalletRpc  # noqa: E402

from mining_dashboard.client.monero.monero_wallet_client import MoneroWalletClient  # noqa: E402


# --- Monero payout wallet (view-only monero-wallet-rpc, #381) ----------------
def test_wallet_confirmed_payouts_parse_and_convert():
    rows = [
        {"txid": "a1", "amount": 250_000_000_000, "height": 100, "timestamp": 1000},
        {"txid": "b2", "amount": 500_000_000_000, "height": 200, "timestamp": 2000},
    ]
    with FakeWalletRpc(transfers=rows) as w:
        client = MoneroWalletClient(url=w.url, username="")  # fake serves no digest auth
        out = client.get_confirmed_payouts(min_height=0)
    assert [p["txid"] for p in out] == ["a1", "b2"]
    assert out[0]["amount_atomic"] == 250_000_000_000 and out[0]["amount_xmr"] == 0.25


def test_wallet_min_height_filters_server_side():
    # The client seeds min_height from the last stored payout; the wallet must honor it so a
    # re-scan of the tip returns only new rows (idempotent storage then drops any overlap).
    rows = [
        {"txid": "old", "amount": 1, "height": 100, "timestamp": 1},
        {"txid": "new", "amount": 2, "height": 300, "timestamp": 2},
    ]
    with FakeWalletRpc(transfers=rows) as w:
        out = MoneroWalletClient(url=w.url, username="").get_confirmed_payouts(min_height=200)
    assert [p["txid"] for p in out] == ["new"]


def test_wallet_no_transfers_yet_reads_empty():
    with FakeWalletRpc(transfers=[]) as w:
        assert MoneroWalletClient(url=w.url, username="").get_confirmed_payouts() == []
