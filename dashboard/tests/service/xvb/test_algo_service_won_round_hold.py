# ruff: noqa: F403, F405
from tests.service.xvb._algo_service_support import *  # noqa: F403


class TestWonRoundHold:
    """In-round donation hold (#769): while a won raffle round may still be live,
    the calibration loop must never steer the donation DOWN — a controller-assisted
    sag of the credited 1h average through the round minimum terminates the round."""

    def _live_win(self):
        return [
            {
                "ts": time.time() - 600,
                "hashrate": 5e6,
                "height": 1,
                "block_id": "x",
                "tier": "donor_whale",
            }
        ]

    def test_downward_step_held_while_round_live(self, algo):
        algo.state_manager.get_raffle_wins.return_value = self._live_win()
        algo.donation_fraction = 0.5
        # 1h average far above reference -> error negative -> would normally trim.
        algo._advance_controller(46_300, 10_000, 200_000, 0.85)
        assert algo.donation_fraction == 0.5  # held, not trimmed

    def test_upward_step_still_ramps_while_round_live(self, algo):
        algo.state_manager.get_raffle_wins.return_value = self._live_win()
        algo.donation_fraction = 0.2
        # Below reference -> catch-up must not be blocked by the hold.
        algo._advance_controller(46_300, 10_000, 0, 0.85)
        assert algo.donation_fraction > 0.2

    def test_upward_step_still_clamped_to_reserve_while_round_live(self, algo):
        algo.state_manager.get_raffle_wins.return_value = self._live_win()
        algo.donation_fraction = 0.5
        for _ in range(100):
            algo._advance_controller(46_300, 10_000, 0, 0.6)
        assert algo.donation_fraction == pytest.approx(0.6)  # VIP reserve still wins

    def test_downward_step_applies_when_no_wins(self, algo):
        algo.donation_fraction = 0.5
        algo._advance_controller(46_300, 10_000, 200_000, 0.85)
        assert algo.donation_fraction < 0.5

    def test_query_window_bounds_round_liveness(self, algo):
        # The liveness read asks storage only for wins inside the hold window —
        # storage filters on ts, so the controller's contract is the `since` bound.
        now = time.time()
        algo.state_manager.get_raffle_wins.return_value = []
        assert algo._won_round_live(now=now) is False
        since = algo.state_manager.get_raffle_wins.call_args.kwargs["since"]
        from mining_dashboard.config.config import XVB_WIN_ROUND_HOLD_S

        assert since == pytest.approx(now - XVB_WIN_ROUND_HOLD_S)

    def test_liveness_fails_open_on_storage_error(self, algo):
        # A broken read must never freeze the controller: hold off, steer normally.
        algo.state_manager.get_raffle_wins.side_effect = RuntimeError("db locked")
        algo.donation_fraction = 0.5
        algo._advance_controller(46_300, 10_000, 200_000, 0.85)
        assert algo.donation_fraction < 0.5  # trimmed as if no round were live

    def test_liveness_treats_non_list_as_not_live(self, algo):
        algo.state_manager.get_raffle_wins.return_value = None
        assert algo._won_round_live() is False

    def test_seed_unaffected_by_live_round(self, algo):
        # First advance seeds the loop; the hold only gates steering afterwards.
        algo.state_manager.get_raffle_wins.return_value = self._live_win()
        assert algo.donation_fraction is None
        algo._advance_controller(46_300, 10_000, 200_000, 0.85)
        assert algo.donation_fraction is not None

    def test_stale_decay_still_wins_over_hold(self, algo):
        # The prolonged-staleness fail-safe outranks the hold: donating blind
        # through an outage is the bigger risk, live round or not.
        algo.state_manager.get_raffle_wins.return_value = self._live_win()
        algo.donation_fraction = 0.4
        with patch("mining_dashboard.service.xvb.algo_service.ENABLE_XVB", True):
            algo.get_decision(
                46_300,
                46_300,
                POOL_STATS,
                P2P_MAIN,
                {"avg_1h": 200_000, "avg_24h": 0, "fail_count": 0, "last_update": _decay_ts()},
                RECENT_SHARES,
            )
        assert algo.donation_fraction < 0.4  # decayed despite the live round
