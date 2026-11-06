# ruff: noqa: F403, F405
from tests.service._data_service_support import *  # noqa: F403


class TestXvbRewardEstimatesSync:
    async def test_success_caches_estimates(self, xvb_service):
        svc, sm = xvb_service
        svc.xvb_client.get_reward_estimates.return_value = {"donor": 0.06, "donor_mega": 56.9}
        await svc._sync_xvb_reward_estimates()
        cached = sm.get_xvb_reward_estimates()
        assert cached["estimates"] == {"donor": 0.06, "donor_mega": 56.9}
        assert cached["last_update"] > 0

    async def test_failed_fetch_writes_nothing(self, xvb_service, monkeypatch):
        svc, sm = xvb_service
        monkeypatch.setattr(time, "time", lambda: 10_000.0)
        svc.xvb_client.get_reward_estimates.return_value = {"donor": 0.06, "donor_mega": 56.9}
        await svc._sync_xvb_reward_estimates()
        before = sm.get_xvb_reward_estimates()
        monkeypatch.setattr(time, "time", lambda: 20_000.0)
        svc.xvb_client.get_reward_estimates.return_value = None
        await svc._sync_xvb_reward_estimates()
        assert sm.get_xvb_reward_estimates() == before
