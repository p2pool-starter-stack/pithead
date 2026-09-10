# ruff: noqa: F403, F405
from tests.service.xvb._algo_service_support import *  # noqa: F403


class TestRunLoop:
    async def test_run_invokes_switch_then_stops(self, algo):
        algo.data_service.latest_data = {
            "total_live_h10": 10_000,
            "total_live_h15": 10_000,
            "pool": {},
            "shares": [],
        }
        algo.state_manager.get_xvb_stats.return_value = {"avg_24h": 0, "avg_1h": 0, "fail_count": 0}
        algo.get_decision = MagicMock(return_value=("P2POOL", 0))
        algo.switch_miners = MagicMock(side_effect=lambda *a, **k: asyncio.sleep(0))
        # Break the infinite loop on the second sleep call.
        with patch("asyncio.sleep", side_effect=[None, Exception("stop")]):
            with pytest.raises(Exception):
                await algo.run()
        assert algo.switch_miners.called

    async def test_run_split_remainder_dwell_holds_split_decision(self, algo):
        """#423 wiring: the SPLIT branch must hand the remainder to _smart_sleep
        with held_decision="SPLIT" — the actuated-duty fix lives in that argument."""
        algo.data_service.latest_data = {
            "total_live_h10": 46_300,
            "total_live_h15": 46_300,
            "pool": {},
            "shares": [],
        }
        algo.state_manager.get_xvb_stats.return_value = {
            "avg_24h": 12_000,
            "avg_1h": 12_000,
            "fail_count": 0,
        }
        algo.get_decision = MagicMock(return_value=("SPLIT", 15_000))
        algo.switch_miners = AsyncMock()
        algo._smart_sleep = AsyncMock(side_effect=Exception("stop"))
        # sleeps: initial 5s, the 15s donated slice, then the error-path sleep raises.
        with patch("asyncio.sleep", side_effect=[None, None, Exception("stop")]):
            with pytest.raises(Exception):
                await algo.run()
        expected_remainder = (XVB_TIME_ALGO_MS - 15_000) / 1000
        algo._smart_sleep.assert_awaited_once_with(expected_remainder, held_decision="SPLIT")

    async def test_run_skips_switching_while_workers_rejected(self, algo):
        # When a node is down and workers are rejected (Issue #31), the proxy is stopped —
        # the loop must not try to reconfigure it.
        algo.data_service.workers_rejected = True
        algo.switch_miners = MagicMock(side_effect=lambda *a, **k: asyncio.sleep(0))
        with patch("asyncio.sleep", side_effect=[None, Exception("stop")]):
            with pytest.raises(Exception):
                await algo.run()
        assert not algo.switch_miners.called
