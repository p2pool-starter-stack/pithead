# ruff: noqa: F403, F405
from tests.service.xvb._algo_service_support import *  # noqa: F403


class TestSmartSleep:
    LATEST = {"total_live_h15": 15_000, "total_live_h10": 15_000, "pool": {}, "shares": []}

    async def test_aborts_early_when_decision_flips_to_donate(self, algo):
        algo.data_service.latest_data = dict(self.LATEST)
        algo.state_manager.get_xvb_stats.return_value = {"avg_24h": 0, "avg_1h": 0, "fail_count": 0}
        algo.get_decision = MagicMock(return_value=("SPLIT", 60_000))
        with patch("asyncio.sleep", new_callable=AsyncMock) as slept:
            await algo._smart_sleep(600, check_interval_sec=30)
        assert slept.await_count == 1  # bailed after the first check

    async def test_aborts_early_when_below_tier(self, algo):
        """Even if the cached decision is P2POOL, a 1h average below the tier means
        we must catch up — bail to re-decide rather than wait out the dwell."""
        algo.data_service.latest_data = dict(self.LATEST)
        algo.state_manager.get_xvb_stats.return_value = {
            "avg_24h": 0,
            "avg_1h": 500,
            "fail_count": 0,
        }
        algo.get_decision = MagicMock(return_value=("P2POOL", 0))
        with patch("asyncio.sleep", new_callable=AsyncMock) as slept:
            await algo._smart_sleep(600, check_interval_sec=30)
        assert slept.await_count == 1

    async def test_split_remainder_not_ended_by_held_split_decision(self, algo):
        """#423: during a SPLIT remainder the re-read decision is SPLIT by
        construction (the fraction is static with advance=False). That must NOT
        end the dwell — pre-fix it did, collapsing every remainder to one tick,
        so the actuated donation duty became slice/(slice+tick) instead of
        slice/cycle: a sustained credited overshoot the controller couldn't
        unwind because its commanded fraction was already near zero."""
        algo.data_service.latest_data = dict(self.LATEST)
        # In tier: 1h above the VIP threshold, so the catch-up override is quiet.
        algo.state_manager.get_xvb_stats.return_value = {
            "avg_24h": 12_000,
            "avg_1h": 12_000,
            "fail_count": 0,
        }
        algo.get_decision = MagicMock(return_value=("SPLIT", 15_000))
        with patch("asyncio.sleep", new_callable=AsyncMock) as slept:
            await algo._smart_sleep(90, check_interval_sec=30, held_decision="SPLIT")
        assert slept.await_count == 3  # full remainder, no early bail

    async def test_split_remainder_still_bails_when_below_tier(self, algo):
        """The catch-up override survives the #423 fix: a fresh below-tier 1h
        average ends even a SPLIT remainder early (undershoot loses the tier)."""
        algo.data_service.latest_data = dict(self.LATEST)
        algo.state_manager.get_xvb_stats.return_value = {
            "avg_24h": 0,
            "avg_1h": 500,
            "fail_count": 0,
        }
        algo.get_decision = MagicMock(return_value=("SPLIT", 15_000))
        with patch("asyncio.sleep", new_callable=AsyncMock) as slept:
            await algo._smart_sleep(600, check_interval_sec=30, held_decision="SPLIT")
        assert slept.await_count == 1

    async def test_split_remainder_bails_when_decision_changes(self, algo):
        """A decision that *changed* from the held one (a constraint tripped —
        shares gone, failures) still ends the remainder early."""
        algo.data_service.latest_data = dict(self.LATEST)
        algo.state_manager.get_xvb_stats.return_value = {
            "avg_24h": 12_000,
            "avg_1h": 12_000,
            "fail_count": 0,
        }
        algo.get_decision = MagicMock(return_value=("P2POOL", 0))
        with patch("asyncio.sleep", new_callable=AsyncMock) as slept:
            await algo._smart_sleep(600, check_interval_sec=30, held_decision="SPLIT")
        assert slept.await_count == 1

    async def test_sleeps_full_duration_when_in_tier_on_p2pool(self, algo):
        algo.data_service.latest_data = dict(self.LATEST)
        # In tier (1h above the VIP threshold) and decision P2POOL -> rest, no bail.
        algo.state_manager.get_xvb_stats.return_value = {
            "avg_24h": 12_000,
            "avg_1h": 12_000,
            "fail_count": 0,
        }
        algo.get_decision = MagicMock(return_value=("P2POOL", 0))
        with patch("asyncio.sleep", new_callable=AsyncMock) as slept:
            await algo._smart_sleep(90, check_interval_sec=30)
        assert slept.await_count == 3  # 90s / 30s ticks, no early abort
