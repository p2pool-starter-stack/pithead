# ruff: noqa: F403, F405
from tests.service._data_service_support import *  # noqa: F403


class TestXvbRewardEstimatesSync:
    """XvB published per-tier reward-estimate fetch (#118)."""

    def _svc(self):
        sm = MagicMock()
        sm.load_snapshot.return_value = None
        xvb = MagicMock()
        return DataService(sm, MagicMock(), xvb), sm, xvb

    async def test_success_caches_estimates(self):
        svc, sm, xvb = self._svc()
        xvb.get_reward_estimates.return_value = {"donor": 0.06, "donor_mega": 56.9}
        await svc._sync_xvb_reward_estimates()
        sm.set_xvb_reward_estimates.assert_called_once_with({"donor": 0.06, "donor_mega": 56.9})

    async def test_failed_fetch_writes_nothing(self):
        # None (failed/unparseable) must leave the cache + last_update frozen so staleness is
        # detectable (#311) — never overwrite the last-good estimates with an empty set.
        svc, sm, xvb = self._svc()
        xvb.get_reward_estimates.return_value = None
        await svc._sync_xvb_reward_estimates()
        sm.set_xvb_reward_estimates.assert_not_called()
