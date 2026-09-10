# ruff: noqa: F403, F405
from tests.service.notify._alert_service_support import *  # noqa: F403


class TestWalletChanged:
    def test_first_observation_seeds_silently(self):
        store, get, put = _kv_store()
        svc = _svc(kv_get=get, kv_set=put)
        assert _ev(svc, observed_wallet=_W_A) == []
        assert store["payout_wallet"] == _W_A

    def test_change_fires_once_then_rearms(self):
        store, get, put = _kv_store()
        svc = _svc(kv_get=get, kv_set=put)
        _ev(svc, observed_wallet=_W_A)  # seed
        alerts = _ev(svc, observed_wallet=_W_B)
        assert _keys(alerts) == [AlertService.EVT_WALLET_CHANGED]
        # Steady state on the new wallet is silent; a further change fires again (re-armed).
        assert _ev(svc, observed_wallet=_W_B) == []
        assert _keys(_ev(svc, observed_wallet=_W_A)) == [AlertService.EVT_WALLET_CHANGED]

    def test_alert_truncates_addresses_to_8_chars(self):
        _store, get, put = _kv_store()
        svc = _svc(kv_get=get, kv_set=put)
        _ev(svc, observed_wallet=_W_A)
        _, text = _ev(svc, observed_wallet=_W_B)[0]
        assert _W_A[:8] in text and _W_B[:8] in text
        # The full addresses must never reach Telegram (chat logs live on Telegram's servers).
        assert _W_A not in text and _W_B not in text

    def test_change_persists_new_baseline_and_ts(self):
        store, get, put = _kv_store()
        svc = _svc(kv_get=get, kv_set=put)
        _ev(svc, observed_wallet=_W_A)
        _ev(svc, observed_wallet=_W_B)
        assert store["payout_wallet"] == _W_B
        assert store["payout_wallet_prev8"] == _W_A[:8]
        assert float(store["payout_wallet_changed_ts"]) > 0

    def test_empty_or_unknown_observation_noops(self):
        # p2pool reports no wallet while restarting — that must neither fire nor re-seed.
        store, get, put = _kv_store()
        svc = _svc(kv_get=get, kv_set=put)
        _ev(svc, observed_wallet=_W_A)
        assert _ev(svc, observed_wallet="") == []
        assert _ev(svc, observed_wallet="Unknown") == []
        assert store["payout_wallet"] == _W_A

    def test_baseline_survives_restart(self):
        # `apply` recreates the dashboard container; the kv baseline (not AlertService memory)
        # must carry across, so a wallet swapped during the recreate still trips the alert.
        store, get, put = _kv_store()
        _ev(_svc(kv_get=get, kv_set=put), observed_wallet=_W_A)  # seed, then "restart"
        svc2 = _svc(kv_get=get, kv_set=put)  # fresh service, same storage
        assert _ev(svc2, observed_wallet=_W_A) == []  # unchanged wallet stays silent
        assert _keys(_ev(svc2, observed_wallet=_W_B)) == [AlertService.EVT_WALLET_CHANGED]

    def test_without_kv_hooks_is_noop(self):
        # Default construction (no storage injected) leaves the tripwire off rather than crashing.
        assert _ev(_svc(), observed_wallet=_W_A) == []
