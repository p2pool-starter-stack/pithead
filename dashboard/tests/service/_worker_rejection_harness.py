# ruff: noqa: F403, F405
from mining_dashboard.collector import pools as pools_collector
from tests.service._data_service_support import *  # noqa: F403


class MiningGuardHarness:
    def _svc(self):
        sm = MagicMock()
        sm.load_snapshot.return_value = None
        svc = DataService(sm, MagicMock(), MagicMock())
        svc.docker_control = MagicMock()
        svc.docker_control.stop = AsyncMock(return_value=True)
        svc.docker_control.start = AsyncMock(return_value=True)
        svc.monero_health.healthy = svc.tari_health.healthy = True
        return svc

    @staticmethod
    def _p2p(**kw):
        return {"p2p": {"uptime": 900, "out_peers": 2, "in_peers": 0, "zmq_active": 3, **kw}}

    async def _cycle(self, svc, p2pool=None, health=None, sync=None, containers=None, signals=None):
        monero_sync = {"health": health or {"level": "green"}, **(sync or {})}
        with (
            patch.object(ds_mod, "get_container_health", AsyncMock(return_value=containers or {})),
            patch.object(
                pools_collector,
                "get_p2pool_log_signals",
                AsyncMock(return_value=signals or {"lag": 0, "monerod_unsynced": False}),
            ),
        ):
            await svc._update_mining_guard(monero_sync, p2pool or self._p2p())
        await svc._apply_worker_rejection(False, False)

    @staticmethod
    def _clock(svc):
        now = [0]
        svc.mining_guard._clock = lambda: now[0]
        return now

    async def _hold_past_grace(self, svc, **kwargs):
        now = self._clock(svc)
        await self._cycle(svc, **kwargs)
        now[0] = 10_000
        await self._cycle(svc, **kwargs)
        return now
