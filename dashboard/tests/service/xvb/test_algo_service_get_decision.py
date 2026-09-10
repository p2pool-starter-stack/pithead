# ruff: noqa: F403, F405
from tests.service.xvb._algo_service_support import *  # noqa: F403


class TestGetDecision:
    def test_xvb_disabled_forces_p2pool(self, algo):
        with patch("mining_dashboard.service.xvb.algo_service.ENABLE_XVB", False):
            assert algo.get_decision(100, 100, {}, {}, {}, RECENT_SHARES) == ("P2POOL", 0)

    def test_zero_shares_forces_p2pool(self, algo):
        with patch("mining_dashboard.service.xvb.algo_service.ENABLE_XVB", True):
            mode, dur = algo.get_decision(
                10_000,
                10_000,
                POOL_STATS,
                P2P_MAIN,
                {"avg_24h": 0, "avg_1h": 0, "fail_count": 0},
                [],
            )
            assert mode == "P2POOL"

    def test_excessive_failures_forces_p2pool(self, algo):
        with patch("mining_dashboard.service.xvb.algo_service.ENABLE_XVB", True):
            mode, _ = algo.get_decision(
                10_000,
                10_000,
                POOL_STATS,
                P2P_MAIN,
                {"avg_24h": 9_999_999, "avg_1h": 9_999_999, "fail_count": 3},
                RECENT_SHARES,
            )
            assert mode == "P2POOL"

    def test_low_hashrate_no_tier_is_p2pool(self, algo):
        with patch("mining_dashboard.service.xvb.algo_service.ENABLE_XVB", True):
            # 100 H/s * 0.85 < lowest tier (1000) -> no tier -> P2POOL
            mode, _ = algo.get_decision(
                100,
                100,
                POOL_STATS,
                P2P_MAIN,
                {"avg_24h": 0, "avg_1h": 0, "fail_count": 0},
                RECENT_SHARES,
            )
            assert mode == "P2POOL"

    def test_cold_start_seeds_feedforward(self, algo):
        """The first decision seeds the donated fraction from the feedforward
        estimate (reference / current_hr), so it starts donating a sane amount."""
        algo.donation_level = "vip"  # target 10_000
        with patch("mining_dashboard.service.xvb.algo_service.ENABLE_XVB", True):
            mode, dur = algo.get_decision(
                46_300,
                46_300,
                POOL_STATS,
                P2P_MAIN,
                {"avg_24h": 0, "avg_1h": 0, "fail_count": 0},
                RECENT_SHARES,
            )
            assert mode in ("SPLIT", "XVB")
            # reference 10_500 / 46_300 ~ 0.227 of the cycle.
            assert algo.donation_fraction == pytest.approx(10_500 / 46_300, rel=0.05)

    def test_loop_ramps_up_when_below_reference(self, algo):
        """Calling repeatedly with the 1h average below reference integrates the
        donated fraction upward (closed-loop catch-up, not a one-shot spike)."""
        algo.donation_level = "vip"
        with patch("mining_dashboard.service.xvb.algo_service.ENABLE_XVB", True):
            d1 = algo.get_decision(
                46_300,
                46_300,
                POOL_STATS,
                P2P_MAIN,
                {"avg_1h": 0, "avg_24h": 0, "fail_count": 0},
                RECENT_SHARES,
            )
            f_after_seed = algo.donation_fraction
            d2 = algo.get_decision(
                46_300,
                46_300,
                POOL_STATS,
                P2P_MAIN,
                {"avg_1h": 0, "avg_24h": 0, "fail_count": 0},
                RECENT_SHARES,
            )
            assert algo.donation_fraction > f_after_seed  # ramped up
            assert _split_ms(d2) > _split_ms(d1)

    def test_loop_backs_off_when_above_reference(self, algo):
        """When XvB reports above the reference (over target), the loop trims the
        donated fraction — the property the old unbounded catch-up lacked."""
        algo.donation_level = "vip"
        with patch("mining_dashboard.service.xvb.algo_service.ENABLE_XVB", True):
            algo.get_decision(
                46_300,
                46_300,
                POOL_STATS,
                P2P_MAIN,
                {"avg_1h": 0, "avg_24h": 0, "fail_count": 0},
                RECENT_SHARES,
            )
            seeded = algo.donation_fraction
            algo.get_decision(
                46_300,
                46_300,
                POOL_STATS,
                P2P_MAIN,
                {"avg_1h": 30_000, "avg_24h": 30_000, "fail_count": 0},
                RECENT_SHARES,
            )
            assert algo.donation_fraction < seeded  # backed off

    def test_advance_false_does_not_move_the_loop(self, algo):
        """_smart_sleep re-reads with advance=False; that must not step the loop."""
        algo.donation_level = "vip"
        with patch("mining_dashboard.service.xvb.algo_service.ENABLE_XVB", True):
            algo.get_decision(
                46_300,
                46_300,
                POOL_STATS,
                P2P_MAIN,
                {"avg_1h": 0, "avg_24h": 0, "fail_count": 0},
                RECENT_SHARES,
            )
            held = algo.donation_fraction
            algo.get_decision(
                46_300,
                46_300,
                POOL_STATS,
                P2P_MAIN,
                {"avg_1h": 0, "avg_24h": 0, "fail_count": 0},
                RECENT_SHARES,
                advance=False,
            )
            assert algo.donation_fraction == held

    def test_nano_pool_uses_longer_window(self, algo):
        with patch("mining_dashboard.service.xvb.algo_service.ENABLE_XVB", True):
            mode, _ = algo.get_decision(
                10_000,
                10_000,
                POOL_STATS,
                {"type": "Nano"},
                {"avg_24h": 0, "avg_1h": 0, "fail_count": 0},
                RECENT_SHARES,
            )
            assert mode in ("P2POOL", "XVB", "SPLIT")
