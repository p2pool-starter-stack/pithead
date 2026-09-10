# ruff: noqa: F403, F405
from tests.service._data_service_support import *  # noqa: F403


class TestFailClosedGate:
    """Opt-in (dashboard.fail_closed, #490) miner hold on an unrecoverable health failure —
    reuses the #35 sync gate's own stop/start mechanism over SYNC_GATE_CONTAINERS, but (unlike
    the sync gate) is not a one-way latch: it re-checks every cycle and releases once the
    unrecoverable condition clears."""

    def _svc(self, released=True):
        sm = MagicMock()
        sm.load_snapshot.return_value = None
        svc = DataService(sm, MagicMock(), MagicMock())
        svc.docker_control = MagicMock()
        svc.docker_control.stop = AsyncMock(return_value=True)
        svc.docker_control.start = AsyncMock(return_value=True)
        svc.miner_released = released
        return svc

    def _enabled(self, on=True):
        return patch.object(ds_mod, "DASHBOARD_FAIL_CLOSED", on)

    async def test_default_off_never_touches_containers(self):
        # dashboard.fail_closed defaults False — an unrecoverable failure must only ever alert
        # (elsewhere), never hold. A cosmetic dashboard fault must not idle the fleet.
        svc = self._svc()
        with (
            self._enabled(False),
            patch.object(ds_mod, "SYNC_GATE_CONTAINERS", ["p2pool", "xmrig-proxy"]),
        ):
            await svc._apply_fail_closed_gate(unrecoverable=True)
        svc.docker_control.stop.assert_not_called()
        svc.docker_control.start.assert_not_called()
        assert svc.fail_closed_held is False

    async def test_noop_before_sync_gate_releases_the_miner(self):
        # Holding before the sync gate has released is already #35's job — engaging here too
        # would just be a second, redundant hold path.
        svc = self._svc(released=False)
        with self._enabled(True), patch.object(ds_mod, "SYNC_GATE_CONTAINERS", ["p2pool"]):
            await svc._apply_fail_closed_gate(unrecoverable=True)
        svc.docker_control.stop.assert_not_called()
        assert svc.fail_closed_held is False

    async def test_holds_when_enabled_and_unrecoverable(self):
        svc = self._svc()
        with (
            self._enabled(True),
            patch.object(ds_mod, "SYNC_GATE_CONTAINERS", ["p2pool", "xmrig-proxy"]),
        ):
            await svc._apply_fail_closed_gate(unrecoverable=True)
        stopped = {c.args[0] for c in svc.docker_control.stop.await_args_list}
        assert stopped == {"p2pool", "xmrig-proxy"}
        svc.docker_control.start.assert_not_called()
        assert svc.fail_closed_held is True

    async def test_rehold_stops_quietly_after_first_cycle(self):
        svc = self._svc()
        with self._enabled(True), patch.object(ds_mod, "SYNC_GATE_CONTAINERS", ["p2pool"]):
            await svc._apply_fail_closed_gate(unrecoverable=True)
            await svc._apply_fail_closed_gate(unrecoverable=True)
        first, second = svc.docker_control.stop.await_args_list
        assert first.kwargs.get("quiet") is False
        assert second.kwargs.get("quiet") is True

    async def test_releases_once_condition_clears(self):
        # Unlike the sync gate's one-way latch, this must release on its own once the
        # unrecoverable condition clears (an operator fix + restart, no full stack restart).
        svc = self._svc()
        svc.fail_closed_held = True
        with (
            self._enabled(True),
            patch.object(ds_mod, "SYNC_GATE_CONTAINERS", ["p2pool", "xmrig-proxy"]),
        ):
            await svc._apply_fail_closed_gate(unrecoverable=False)
        started = {c.args[0] for c in svc.docker_control.start.await_args_list}
        assert started == {"p2pool", "xmrig-proxy"}
        svc.docker_control.stop.assert_not_called()
        assert svc.fail_closed_held is False

    async def test_partial_start_failure_stays_held(self):
        svc = self._svc()
        svc.fail_closed_held = True
        svc.docker_control.start = AsyncMock(side_effect=[True, False])
        with (
            self._enabled(True),
            patch.object(ds_mod, "SYNC_GATE_CONTAINERS", ["p2pool", "xmrig-proxy"]),
        ):
            await svc._apply_fail_closed_gate(unrecoverable=False)
        assert svc.fail_closed_held is True  # next cycle retries

    async def test_not_a_one_way_latch_can_rehold_after_release(self):
        # The defining difference from the #35 sync gate: a later unrecoverable condition (a
        # second DB-recovery failure) must be able to hold again after an earlier release.
        svc = self._svc()
        with self._enabled(True), patch.object(ds_mod, "SYNC_GATE_CONTAINERS", ["p2pool"]):
            await svc._apply_fail_closed_gate(unrecoverable=True)
            assert svc.fail_closed_held is True
            await svc._apply_fail_closed_gate(unrecoverable=False)
            assert svc.fail_closed_held is False
            await svc._apply_fail_closed_gate(unrecoverable=True)
            assert svc.fail_closed_held is True

    async def test_healthy_and_never_held_is_a_noop(self):
        svc = self._svc()
        with self._enabled(True), patch.object(ds_mod, "SYNC_GATE_CONTAINERS", ["p2pool"]):
            await svc._apply_fail_closed_gate(unrecoverable=False)
        svc.docker_control.start.assert_not_called()
        svc.docker_control.stop.assert_not_called()

    async def test_real_trigger_a_transient_unhealthy_dashboard_does_not_gate(self):
        # #490 F1/F2: wire the ACTUAL trigger expression the run loop computes
        # (is_db_unrecoverable OR containers.is_confirmed_bad("dashboard")) from real objects, and
        # prove a first-sighting-unhealthy dashboard (a seed, unvetted by the 120s debounce) does
        # NOT hold the fleet. The hardcoded-bool gate tests above cover the mechanism; this covers
        # the classification that feeds it.
        from mining_dashboard.service.storage_service import StateManager

        svc = self._svc()
        sm = StateManager(db_path=":memory:")
        try:
            svc.state_manager = sm
            svc.alert_service.containers.update(
                {
                    "dashboard": {
                        "running": True,
                        "restarting": False,
                        "restart_count": 0,
                        "health": "unhealthy",
                    }
                }
            )
            assert sm.is_db_unrecoverable() is False  # healthy DB
            trigger = sm.is_db_unrecoverable() or svc.alert_service.containers.is_confirmed_bad(
                "dashboard"
            )
            assert trigger is False  # seed is not confirmed -> no gate
            with self._enabled(True), patch.object(ds_mod, "SYNC_GATE_CONTAINERS", ["p2pool"]):
                await svc._apply_fail_closed_gate(trigger)
            svc.docker_control.stop.assert_not_called()
            assert svc.fail_closed_held is False
        finally:
            sm.close()
