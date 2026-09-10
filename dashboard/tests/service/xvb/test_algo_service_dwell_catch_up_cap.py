# ruff: noqa: F403, F405
from tests.service.xvb._algo_service_support import *  # noqa: F403


class TestDwellCatchUpCap:
    """#898: the under-tier catch-up must chase the ACHIEVABLE donation (stable_hr x cap), not
    the raw tier target — an unreachable explicit target otherwise ends every p2pool dwell at
    its first check tick and the cap never binds (measured live: ~94% routed under a 0.65 cap)."""

    def _fresh(self, avg_1h):
        return {"avg_1h": avg_1h, "avg_24h": avg_1h, "last_update": time.time()}

    def test_unreachable_target_does_not_end_dwell_once_cap_is_met(self, algo):
        # mega target on a 268k fleet with cap 0.65: achievable = 174.2k. Credited 200k is
        # under the 1M target but ABOVE achievable — the dwell must run its course.
        algo.donation_level = "mega"
        algo.max_donation_fraction = 0.65
        with patch.object(algo, "get_decision", return_value=("SPLIT", 1000)):
            assert (
                algo._dwell_should_end("SPLIT", 268_000, 268_000, {}, {}, self._fresh(200_000), [])
                is False
            )

    def test_catch_up_still_fires_below_the_achievable_ceiling(self, algo):
        algo.donation_level = "mega"
        algo.max_donation_fraction = 0.65
        with patch.object(algo, "get_decision", return_value=("SPLIT", 1000)):
            assert (
                algo._dwell_should_end("SPLIT", 268_000, 268_000, {}, {}, self._fresh(150_000), [])
                is True
            )

    def test_reachable_target_keeps_the_original_behaviour(self, algo):
        # whale on the same fleet: target 100k < achievable 174.2k — the raw-tier comparison
        # is unchanged (under 100k ends the dwell, above it does not).
        algo.donation_level = "whale"
        algo.max_donation_fraction = 0.65
        with patch.object(algo, "get_decision", return_value=("SPLIT", 1000)):
            assert (
                algo._dwell_should_end("SPLIT", 268_000, 268_000, {}, {}, self._fresh(90_000), [])
                is True
            )
            assert (
                algo._dwell_should_end("SPLIT", 268_000, 268_000, {}, {}, self._fresh(105_000), [])
                is False
            )
