# ruff: noqa: F403, F405
from tests.service.xvb._algo_service_support import *  # noqa: F403


class TestWarmResume:
    """Warm-resume of the closed-loop state on restart / backup failover (#249).

    The seed precedence is: this host's own persisted commanded fraction (a restart, or a stack
    that has already steered) beats the primary's standby (a first failover), which beats the cold
    feedforward estimate (a fresh install with no history)."""

    def test_seed_prefers_own_persisted_fraction(self, algo):
        # Own state wins over standby: an authoritative stack owns its steering, so a stale standby
        # from a departed primary can't override it.
        algo.state_manager.get_xvb_stats.return_value = {"commanded_fraction": 0.4}
        algo.state_manager.get_xvb_standby.return_value = {"commanded_fraction": 0.9}
        assert algo._seed_donation_fraction(1000, 2000, 0.85) == 0.4

    def test_seed_adopts_standby_when_no_own_state(self, algo):
        # The failover case: an idle backup never steered (own fraction 0.0), so at handover it
        # adopts the primary's last-known commanded fraction.
        algo.state_manager.get_xvb_stats.return_value = {"commanded_fraction": 0.0}
        algo.state_manager.get_xvb_standby.return_value = {"commanded_fraction": 0.3}
        assert algo._seed_donation_fraction(1000, 2000, 0.85) == 0.3

    def test_seed_clamps_standby_to_vip_reserve(self, algo):
        algo.state_manager.get_xvb_stats.return_value = {"commanded_fraction": 0.0}
        algo.state_manager.get_xvb_standby.return_value = {"commanded_fraction": 0.99}
        assert algo._seed_donation_fraction(1000, 2000, 0.5) == 0.5

    def test_seed_cold_start_uses_feedforward_when_no_state(self, algo):
        # Fresh install: no own state, no standby -> the original feedforward seed, unchanged.
        algo.state_manager.get_xvb_stats.return_value = {"commanded_fraction": 0.0}
        algo.state_manager.get_xvb_standby.return_value = None
        # reference = 1000 + min(1000*0.05, 5000) = 1050; feedforward = 1050 / current_hr.
        assert algo._seed_donation_fraction(1000, 2000, 0.85) == pytest.approx(1050 / 2000)

    def test_get_decision_seeds_from_standby_on_failover(self, algo):
        # Integration: the first real donating cycle on a warm backup adopts the standby fraction
        # rather than cold-ramping from feedforward.
        algo.state_manager.get_xvb_stats.return_value = {"commanded_fraction": 0.0}
        algo.state_manager.get_xvb_standby.return_value = {"commanded_fraction": 0.35}
        assert algo.donation_fraction is None
        algo.get_decision(
            2000,
            2000,
            POOL_STATS,
            P2P_MAIN,
            {"avg_1h": 500, "last_update": _fresh_ts()},
            RECENT_SHARES,
        )
        assert algo.donation_fraction == pytest.approx(0.35)
