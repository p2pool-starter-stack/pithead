# ruff: noqa: F403, F405
from tests.service.xvb._algo_service_support import *  # noqa: F403


class TestDwellReserveCap:
    def _fresh(self, avg_1h):
        return {"avg_1h": avg_1h, "avg_24h": avg_1h, "last_update": time.time()}

    def _ended(self, algo, hr, difficulty, avg_1h):
        algo.donation_level = "auto"
        algo.max_donation_fraction = 0.85
        pool = {"difficulty": difficulty}
        with patch.object(algo, "get_decision", return_value=("P2POOL", 0)):
            return algo._dwell_should_end("P2POOL", hr, hr, pool, {}, self._fresh(avg_1h), [])

    def test_reserve_capped_fleet_keeps_dwelling(self, algo):
        assert self._ended(algo, 40_000, 400_000_000, 0) is False

    def test_zero_cap_fleet_does_not_switch_every_tick(self, algo):
        assert self._ended(algo, 5_000, 100_000_000, 0) is False

    def test_cap_covering_target_catches_up_as_before(self, algo):
        assert self._ended(algo, 300_000, 1_000_000_000, 0) is True
        assert self._ended(algo, 300_000, 1_000_000_000, 10**9) is False
