# ruff: noqa: F403, F405
from tests.service.xvb._algo_service_support import *  # noqa: F403


class TestHelpers:
    def test_reference_cushion_is_absolute_capped(self, algo):
        # Cushion above target is capped in ABSOLUTE H/s, so a huge tier doesn't
        # waste a percentage of a huge number.
        assert algo._reference_hr(1_000_000) == pytest.approx(1_000_000 + 5_000)
        # Small tier uses the percentage (5% of 10k = 500).
        assert algo._reference_hr(10_000) == pytest.approx(10_500)
        # Whale sits exactly at the cap: 5% of 100k = 5k, the measured credited
        # noise (~2.5 kH/s dips) stays clear of the round minimum.
        assert algo._reference_hr(100_000) == pytest.approx(105_000)

    def test_fraction_to_ms_zero_and_positive(self, algo):
        assert algo._fraction_to_ms(0) == 0
        assert algo._fraction_to_ms(-1) == 0
        assert algo._fraction_to_ms(0.2) == pytest.approx(
            0.2 * XVB_TIME_ALGO_MS + XVB_SWITCH_OVERHEAD_MS, abs=1
        )

    def test_advance_noop_when_no_hashrate(self, algo):
        algo.donation_fraction = 0.3
        algo._advance_controller(0, 10_000, 0, 0.85)
        assert algo.donation_fraction == 0.3  # unchanged

    def test_advance_clamps_to_bounds(self, algo):
        algo.donation_fraction = 0.5
        # Way above reference -> error negative -> would go negative -> clamps at 0.
        for _ in range(100):
            algo._advance_controller(46_300, 10_000, 10_000_000, 0.85)
        assert algo.donation_fraction == 0.0

    def test_routed_fraction_for_instrumentation(self, algo):
        assert algo._routed_fraction("P2POOL", 0) == 0.0
        assert algo._routed_fraction("XVB", XVB_TIME_ALGO_MS) == 1.0
        assert algo._routed_fraction("SPLIT", XVB_TIME_ALGO_MS // 2) == pytest.approx(0.5)

    def test_get_target_uses_state_manager_tiers(self, algo):
        algo.state_manager.get_tiers.return_value = {"donor": 1_000}
        # 2000 * 0.85 = 1700 >= 1000 -> threshold 1000
        assert algo._get_target_donation_hr(2_000) == 1_000

    def test_default_auto_targets_highest_sustainable(self, algo):
        # 1_000_000 * 0.85 = 850_000 -> Whale (100_000).
        assert algo._get_target_donation_hr(1_000_000) == 100_000

    def test_explicit_tier_not_downgraded(self, algo):
        algo.donation_level = "mega"
        assert algo._get_target_donation_hr(15_000) == 1_000_000
