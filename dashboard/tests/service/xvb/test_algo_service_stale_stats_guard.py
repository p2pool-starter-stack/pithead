# ruff: noqa: F403, F405
from tests.service.xvb._algo_service_support import *  # noqa: F403


class TestStaleStatsGuard:
    """#311: when the xmrvsbeast.com stats fetch goes quiet, avg_1h freezes. The
    controller must not keep steering off that frozen number (it over-donates against
    a target it can't refresh). `last_update` (bumped only on a real fetch, #136) is
    the freshness signal."""

    def test_predicate_cold_start_is_not_stale(self, algo):
        # Never fetched (no/zero last_update) -> cold start, NOT stale: the
        # feedforward ramp must be left alone to climb to tier.
        assert algo._stats_are_stale({}) is False
        assert algo._stats_are_stale({"last_update": 0}) is False

    def test_predicate_fresh_is_not_stale(self, algo):
        assert algo._stats_are_stale({"last_update": _fresh_ts()}) is False

    def test_predicate_old_fetch_is_stale(self, algo):
        assert algo._stats_are_stale({"last_update": _stale_ts()}) is True

    def test_stale_read_holds_fraction_instead_of_winding_up(self, algo):
        """The bug: a frozen avg_1h below reference keeps ramping the donated
        fraction up. With a stale read the loop must HOLD, not advance."""
        algo.donation_level = "vip"
        with patch("mining_dashboard.service.xvb.algo_service.ENABLE_XVB", True):
            # Seed from a fresh reading so we have a sane held fraction.
            algo.get_decision(
                46_300,
                46_300,
                POOL_STATS,
                P2P_MAIN,
                {"avg_1h": 0, "avg_24h": 0, "fail_count": 0, "last_update": _fresh_ts()},
                RECENT_SHARES,
            )
            held = algo.donation_fraction
            # Now the fetch is stale and frozen below reference — must NOT ramp.
            for _ in range(10):
                algo.get_decision(
                    46_300,
                    46_300,
                    POOL_STATS,
                    P2P_MAIN,
                    {"avg_1h": 0, "avg_24h": 0, "fail_count": 0, "last_update": _stale_ts()},
                    RECENT_SHARES,
                )
            assert algo.donation_fraction == held  # held, not wound up

    def test_fresh_read_below_reference_still_ramps(self, algo):
        """Guard against over-correcting: a *fresh* below-tier read must still drive
        the #9/#70 catch-up. Only stale reads are frozen out."""
        algo.donation_level = "vip"
        with patch("mining_dashboard.service.xvb.algo_service.ENABLE_XVB", True):
            algo.get_decision(
                46_300,
                46_300,
                POOL_STATS,
                P2P_MAIN,
                {"avg_1h": 0, "avg_24h": 0, "fail_count": 0, "last_update": _fresh_ts()},
                RECENT_SHARES,
            )
            seeded = algo.donation_fraction
            algo.get_decision(
                46_300,
                46_300,
                POOL_STATS,
                P2P_MAIN,
                {"avg_1h": 0, "avg_24h": 0, "fail_count": 0, "last_update": _fresh_ts()},
                RECENT_SHARES,
            )
            assert algo.donation_fraction > seeded  # fresh read still ramps

    def test_prolonged_stale_decays_fraction_toward_zero(self, algo):
        """Past the longer decay grace, holding blind is the bigger risk: the fail-safe
        must bleed the held fraction toward 0, not freeze it (the short-hold behavior)."""
        algo.donation_level = "vip"
        with patch("mining_dashboard.service.xvb.algo_service.ENABLE_XVB", True):
            # Seed a real held fraction from a fresh read.
            algo.get_decision(
                46_300,
                46_300,
                POOL_STATS,
                P2P_MAIN,
                {"avg_1h": 0, "avg_24h": 0, "fail_count": 0, "last_update": _fresh_ts()},
                RECENT_SHARES,
            )
            held = algo.donation_fraction
            assert held > 0
            # One cycle past the decay grace: strictly smaller than the held fraction.
            algo.get_decision(
                46_300,
                46_300,
                POOL_STATS,
                P2P_MAIN,
                {"avg_1h": 0, "avg_24h": 0, "fail_count": 0, "last_update": _decay_ts()},
                RECENT_SHARES,
            )
            assert algo.donation_fraction < held
            # Keep decaying: it converges to exactly 0 (snapped at the floor), fully stopping.
            for _ in range(20):
                algo.get_decision(
                    46_300,
                    46_300,
                    POOL_STATS,
                    P2P_MAIN,
                    {"avg_1h": 0, "avg_24h": 0, "fail_count": 0, "last_update": _decay_ts()},
                    RECENT_SHARES,
                )
            assert algo.donation_fraction == 0.0

    def test_fresh_read_resumes_control_after_decay(self, algo):
        """The decay is a fail-safe, not a latch: once a genuine fetch lands again the
        controller must resume normal steering from the decayed fraction."""
        algo.donation_level = "vip"
        with patch("mining_dashboard.service.xvb.algo_service.ENABLE_XVB", True):
            algo.get_decision(
                46_300,
                46_300,
                POOL_STATS,
                P2P_MAIN,
                {"avg_1h": 0, "avg_24h": 0, "fail_count": 0, "last_update": _fresh_ts()},
                RECENT_SHARES,
            )
            # Decay it down over a prolonged outage.
            for _ in range(5):
                algo.get_decision(
                    46_300,
                    46_300,
                    POOL_STATS,
                    P2P_MAIN,
                    {"avg_1h": 0, "avg_24h": 0, "fail_count": 0, "last_update": _decay_ts()},
                    RECENT_SHARES,
                )
            decayed = algo.donation_fraction
            # A fresh, below-reference read resumes the catch-up ramp (advance runs again).
            algo.get_decision(
                46_300,
                46_300,
                POOL_STATS,
                P2P_MAIN,
                {"avg_1h": 0, "avg_24h": 0, "fail_count": 0, "last_update": _fresh_ts()},
                RECENT_SHARES,
            )
            assert algo.donation_fraction > decayed  # control resumed, not still decaying

    async def test_smart_sleep_does_not_bail_early_on_stale_below_tier(self, algo):
        """The dominant symptom (#311): a frozen below-tier avg_1h made _smart_sleep
        end every p2pool dwell early, driving the effective split to ~55% XvB. With a
        stale read the under-tier override must pause — let the dwell run."""
        algo.data_service.latest_data = {
            "total_live_h15": 15_000,
            "total_live_h10": 15_000,
            "pool": {},
            "shares": [],
        }
        algo.state_manager.get_xvb_stats.return_value = {
            "avg_24h": 0,
            "avg_1h": 500,  # frozen far below tier
            "fail_count": 0,
            "last_update": _stale_ts(),
        }
        algo.get_decision = MagicMock(return_value=("P2POOL", 0))
        with patch("asyncio.sleep", new_callable=AsyncMock) as slept:
            await algo._smart_sleep(90, check_interval_sec=30)
        assert slept.await_count == 3  # full dwell, no early bail

    async def test_smart_sleep_still_bails_on_fresh_below_tier(self, algo):
        """Regression guard: the catch-up early-exit must still fire on a FRESH
        below-tier read (mirrors test_aborts_early_when_below_tier with last_update)."""
        algo.data_service.latest_data = {
            "total_live_h15": 15_000,
            "total_live_h10": 15_000,
            "pool": {},
            "shares": [],
        }
        algo.state_manager.get_xvb_stats.return_value = {
            "avg_24h": 0,
            "avg_1h": 500,
            "fail_count": 0,
            "last_update": _fresh_ts(),
        }
        algo.get_decision = MagicMock(return_value=("P2POOL", 0))
        with patch("asyncio.sleep", new_callable=AsyncMock) as slept:
            await algo._smart_sleep(600, check_interval_sec=30)
        assert slept.await_count == 1  # bailed early to catch up
