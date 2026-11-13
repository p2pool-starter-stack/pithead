import time
from types import SimpleNamespace

from mining_dashboard.config import config
from mining_dashboard.service.notify.telegram_commands import TelegramCommandBot
from mining_dashboard.web.views.views import build_state

_WALLET_A = "wallet-alpha"
_WALLET_B = "wallet-beta"


def _set_wallet(monkeypatch, payout_identity, chain, wallet):
    if chain == "tari":
        monkeypatch.setattr(payout_identity, "decode_address", lambda value: value.encode())
        monkeypatch.setattr(payout_identity, "address_key", lambda raw: raw)
        monkeypatch.setattr(config, "TARI_WALLET_ADDRESS", wallet)
    else:
        monkeypatch.setattr(config, "MONERO_WALLET_ADDRESS", wallet)
    return payout_identity.configured_wallet_id(chain)


def _payout(txid, ts, amount):
    return {"txid": txid, "height": amount, "ts": ts, "amount_atomic": amount}


def test_state_series_earnings_and_completeness_read_current_wallet_only(
    tmp_path, monkeypatch, _data
):
    from mining_dashboard.service import payout_identity
    from mining_dashboard.service.storage_service import StateManager

    monkeypatch.setattr(config, "PAYOUT_CONFIRM_ENABLED", True)
    monkeypatch.setattr(config, "TARI_PAYOUT_CONFIRM_ENABLED", True)
    store = StateManager(db_path=str(tmp_path / "views.db"))
    now = time.time()
    old_ts = now - 40 * 86_400
    current_ts = now - 60
    try:
        identities = {}
        for chain in ("monero", "tari"):
            wallet_a = _set_wallet(monkeypatch, payout_identity, chain, _WALLET_A)
            store.add_payouts(chain, wallet_a, [_payout("old-wallet", old_ts, 1)])
            wallet_b = _set_wallet(monkeypatch, payout_identity, chain, _WALLET_B)
            store.add_payouts(chain, wallet_b, [_payout("current-wallet", current_ts, 2)])
            identities[chain] = wallet_b

        state = build_state(_data(), store, "all")

        assert state["earnings"]["confirmed"]["count"] == 1
        assert state["earnings"]["confirmed"]["xmr_all"] == 2 / 1_000_000_000_000
        assert state["earnings"]["confirmed"]["since_ts"] == current_ts
        assert state["earnings"]["confirmed"]["partial"]["30d"] is True
        assert state["earnings"]["tari_confirmed"]["count"] == 1
        assert state["earnings"]["tari_confirmed"]["xtm_all"] == 2 / 1_000_000
        assert state["earnings"]["tari_confirmed"]["since_ts"] == current_ts
        assert state["payouts"]["monero"] == [{"x": int(current_ts * 1000), "amount": 2}]
        assert state["payouts"]["tari"] == [{"x": int(current_ts * 1000), "amount": 2}]

        service = SimpleNamespace(state_manager=store)
        bot = TelegramCommandBot(
            service, enabled=True, bot_token="fixture-token", chat_id="fixture-chat", host_label=""
        )
        monero = bot._payout_summary("monero")
        tari = bot._payout_summary("tari")
        assert monero["count"] == 1 and monero["xmr_all"] == 2 / 1_000_000_000_000
        assert tari["count"] == 1 and tari["xtm_all"] == 2 / 1_000_000
        assert store.get_payouts("monero", identities["monero"])[0]["txid"] == "current-wallet"
        assert store.get_payouts("tari", identities["tari"])[0]["txid"] == "current-wallet"
    finally:
        store.close()


def test_missing_current_identity_exposes_no_payout_history(tmp_path, monkeypatch, _data):
    from mining_dashboard.service import payout_identity
    from mining_dashboard.service.storage_service import StateManager

    monkeypatch.setattr(config, "PAYOUT_CONFIRM_ENABLED", True)
    monkeypatch.setattr(config, "TARI_PAYOUT_CONFIRM_ENABLED", True)
    store = StateManager(db_path=str(tmp_path / "missing.db"))
    try:
        for chain in ("monero", "tari"):
            wallet_id = _set_wallet(monkeypatch, payout_identity, chain, _WALLET_A)
            store.add_payouts(chain, wallet_id, [_payout("stored", time.time(), 3)])
        monkeypatch.setattr(config, "MONERO_WALLET_ADDRESS", "")
        monkeypatch.setattr(config, "TARI_WALLET_ADDRESS", "")

        state = build_state(_data(), store, "all")

        assert state["earnings"]["confirmed"]["count"] == 0
        assert state["earnings"]["tari_confirmed"]["count"] == 0
        assert state["payouts"] == {"monero": [], "tari": []}
        service = SimpleNamespace(state_manager=store)
        bot = TelegramCommandBot(
            service, enabled=True, bot_token="fixture-token", chat_id="fixture-chat", host_label=""
        )
        assert bot._payout_summary("monero")["count"] == 0
        assert bot._payout_summary("tari")["count"] == 0
    finally:
        store.close()
