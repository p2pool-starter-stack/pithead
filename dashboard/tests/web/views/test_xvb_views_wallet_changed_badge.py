# ruff: noqa: F403, F405
from tests.web.views._xvb_views_support import *  # noqa: F403


class TestWalletChangedBadge:
    _NEW = "4B" + "b" * 93

    def _kv_mgr(self, **kv):
        sm = MagicMock()
        sm.get_kv.side_effect = kv.get
        return sm

    def test_recent_change_within_72h(self):
        sm = self._kv_mgr(
            payout_wallet_changed_ts="1000",
            payout_wallet=self._NEW,
            payout_wallet_prev8="4Aaaaaaa",
        )
        wc = recent_wallet_change(sm, now=1000 + 71 * 3600)
        assert wc == {"old8": "4Aaaaaaa", "new8": self._NEW[:8], "ts": 1000.0}

    def test_expired_after_72h(self):
        sm = self._kv_mgr(payout_wallet_changed_ts="1000", payout_wallet=self._NEW)
        assert recent_wallet_change(sm, now=1000 + 72 * 3600) is None

    def test_no_change_recorded(self):
        assert recent_wallet_change(self._kv_mgr()) is None

    def test_unreadable_ts_is_no_change(self):
        assert recent_wallet_change(self._kv_mgr(payout_wallet_changed_ts="junk")) is None

    def test_badge_rendered_and_truncated(self, _metrics):
        wc = {"old8": "4Aaaaaaa", "new8": self._NEW[:8], "ts": 1000.0}
        out = build_badges({}, _metrics(), "ok", wallet_change=wc)
        badge = next(b for b in out if "Payout wallet changed" in b["text"])
        assert badge["variant"] == "warn"
        assert "4Aaaaaaa…" in badge["title"] and f"{self._NEW[:8]}…" in badge["title"]
        assert self._NEW not in badge["title"]  # never the full address

    def test_shown_even_while_syncing(self, _metrics):
        wc = {"old8": "4Aaaaaaa", "new8": self._NEW[:8], "ts": 1000.0}
        out = build_badges({}, _metrics(global_syncing=True), "ok", wallet_change=wc)
        assert any("Payout wallet changed" in b["text"] for b in out)

    def test_no_badge_without_recent_change(self, _metrics):
        out = build_badges({}, _metrics(), "ok", wallet_change=None)
        assert not any("Payout wallet" in b["text"] for b in out)

    def test_build_state_surfaces_the_badge_from_kv(self, _data, _state_mgr):
        sm = _state_mgr()
        sm.get_kv.side_effect = {
            "payout_wallet_changed_ts": str(time.time() - 60),
            "payout_wallet": self._NEW,
            "payout_wallet_prev8": "4Aaaaaaa",
        }.get
        st = views.build_state(_data(), sm, "all")
        assert any("Payout wallet changed" in b["text"] for b in st["badges"])
