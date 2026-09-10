# ruff: noqa: F403, F405
from tests.web.views._xvb_views_support import *  # noqa: F403


class TestEarnings:
    _NET = {"network": {"reward": 600_000_000_000}}  # 0.6 XMR block reward (atomic units)

    def test_publishes_rate_and_inputs(self, _metrics):
        # The server sends the daily XMR-per-H/s *rate* + the raw inputs the client scales/inverts
        # (the P2Pool hashrate, P2Pool share difficulty) — not pre-formatted earnings.
        e = build_earnings(
            self._NET,
            _metrics(
                p2pool_1h=10500, network_difficulty=400_000_000_000, pool_difficulty=250_000_000
            ),
        )
        assert e["available"] is True
        assert e["p2pool_hr"] == 10500
        assert e["p2pool_hr_str"] == "10.50 kH/s"
        assert e["pool_difficulty"] == 250_000_000
        assert e["block_reward"] == "0.6000 XMR"
        # The disclaimer makes the P2Pool-only scope explicit (not XvB / not Tari).
        assert e["disclaimer"] and "P2Pool mining only" in e["disclaimer"]
        # Rate matches reward_xmr / difficulty * 86400.
        assert e["coeff_day"] == pytest.approx(0.6 / 400_000_000_000 * 86_400)

    def test_default_hashrate_is_the_displayed_p2pool_1h(self, _hashrate, _metrics):
        # Consistency: the calculator's default must be the *same* P2Pool 1h average shown in the
        # header / Overview (metrics.p2pool_1h) — not the total, and not a bespoke total-minus-routed
        # figure. That recorded average already excludes the XvB-donated slice, so the value here
        # (and its display string) matches build_hashrate's "p2p_1h" exactly.
        m = _metrics(total_h15=46_300, xvb_routed_1h=10_000, p2pool_1h=35_000)
        e = build_earnings(self._NET, m)
        assert e["p2pool_hr"] == 35_000  # p2pool_1h, independent of total/routed
        assert (
            e["p2pool_hr_str"] == _hashrate(m)["p2p_1h"]
        )  # identical display string to the header

    def test_no_p2pool_hashrate_when_average_is_zero(self, _metrics):
        # E.g. fresh start (no history) or full-XvB: p2pool_1h is 0 -> client shows 0 / "—" (honest).
        e = build_earnings(self._NET, _metrics(p2pool_1h=0))
        assert e["p2pool_hr"] == 0.0

    def test_unavailable_when_network_reward_missing(self, _metrics):
        # No reward collected yet -> rate is unavailable; the card degrades to "—" (no crash).
        e = build_earnings({}, _metrics(network_difficulty=400_000_000_000))
        assert e["available"] is False
        assert e["coeff_day"] == 0.0
        assert e["block_reward"] == "0.0000 XMR"

    def test_unavailable_when_difficulty_missing(self, _metrics):
        e = build_earnings(self._NET, _metrics(network_difficulty=0))
        assert e["available"] is False
        assert e["coeff_day"] == 0.0

    def test_p2pool_hr_passthrough_is_raw(self, _metrics):
        # The what-if default must be the exact P2Pool H/s (not the rounded display string), so
        # the client's default estimate isn't skewed by display rounding.
        e = build_earnings(self._NET, _metrics(p2pool_1h=10543.7))
        assert e["p2pool_hr"] == 10543.7

    def test_tari_rate_published_when_merge_mining(self, _metrics):
        # #117: with live Tari figures + merge-mining active, the payload carries the XTM rate
        # (reward_xtm / difficulty * 86400) for the client to scale — same shape as coeff_day.
        e = build_earnings(
            self._NET,
            _metrics(tari_mining=True, tari_reward=13_000.0, tari_difficulty=420_000_000_000),
        )
        assert e["tari_available"] is True
        assert e["tari_coeff_day"] == pytest.approx(13_000.0 / 420_000_000_000 * 86_400)
        # Solo merge-mining headline (#117 v1.3.1): the seconds-to-block-per-H/s figure (== the
        # Tari difficulty, so the client does diff / hashrate) and the full per-block reward.
        assert e["tari_difficulty"] == pytest.approx(420_000_000_000)
        assert e["tari_reward"] == pytest.approx(13_000.0)

    def test_tari_unavailable_without_figures_or_mining(self, _metrics):
        # No difficulty collected (inactive/syncing) → unavailable; and a positive rate with
        # merge-mining OFF must also read unavailable (a dead channel earns no phantom XTM).
        e = build_earnings(self._NET, _metrics(tari_mining=True, tari_reward=13_000.0))
        assert e["tari_available"] is False
        assert e["tari_coeff_day"] == 0.0
        e = build_earnings(
            self._NET,
            _metrics(tari_mining=False, tari_reward=13_000.0, tari_difficulty=420_000_000_000),
        )
        assert e["tari_available"] is False

    def test_tari_unavailability_leaves_xmr_estimate_intact(self, _metrics):
        # Tari degrading to "—" must not drag the XMR side down: available stays True.
        e = build_earnings(self._NET, _metrics(tari_mining=False))
        assert e["available"] is True
        assert e["coeff_day"] > 0

    def test_confirmed_disabled_by_default(self, _metrics):
        # No payouts passed (feature off) → the confirmed block reports disabled; UI shows only estimate.
        e = build_earnings(self._NET, _metrics())
        assert e["confirmed"] == {"enabled": False}

    # ponytail: the yesterday/24h/7d/30d/all windowing math is proven once, in
    # tests/service/xvb/test_earnings.py::TestConfirmedPayoutsSummary — this class only asserts
    # build_earnings passes payouts through (enabled/empty/disabled).

    def test_confirmed_enabled_but_empty(self, _metrics):
        # Feature on, nothing confirmed yet → enabled with zeroed totals (shows 0.000000, not "—").
        # No history on record, so every running window is flagged partial (#787).
        e = build_earnings(self._NET, _metrics(), payouts=[])
        assert e["confirmed"] == {
            "enabled": True,
            "count": 0,
            "xmr_24h": 0.0,
            "xmr_yesterday": 0.0,
            "xmr_7d": 0.0,
            "xmr_30d": 0.0,
            "xmr_all": 0.0,
            "n_30d": 0,
            "last_ts": 0,
            "since_ts": 0,
            "partial": {"yesterday": True, "7d": True, "30d": True},
        }

    def test_tari_confirmed_disabled_by_default(self, _metrics):
        # No tari_payouts passed (Tari feature off) → tari_confirmed reports disabled.
        e = build_earnings(self._NET, _metrics())
        assert e["tari_confirmed"] == {"enabled": False}

    def test_tari_confirmed_enabled_but_empty(self, _metrics):
        e = build_earnings(self._NET, _metrics(), tari_payouts=[])
        assert e["tari_confirmed"] == {
            "enabled": True,
            "count": 0,
            "xtm_24h": 0.0,
            "xtm_yesterday": 0.0,
            "xtm_7d": 0.0,
            "xtm_30d": 0.0,
            "xtm_all": 0.0,
            "n_30d": 0,
            "last_ts": 0,
            "since_ts": 0,
            "partial": {"yesterday": True, "7d": True, "30d": True},
        }
