# ruff: noqa: F403, F405
import mining_dashboard.collector.logs as logs_mod
from tests.service._data_service_support import *  # noqa: F403


class TestSyncGate:
    """Hold p2pool + xmrig-proxy until the required chain(s) finish their initial sync (#35)."""

    def _svc(self):
        sm = MagicMock()
        sm.load_snapshot.return_value = None
        svc = DataService(sm, MagicMock(), MagicMock())
        svc.docker_control = MagicMock()
        svc.docker_control.stop = AsyncMock(return_value=True)
        svc.docker_control.start = AsyncMock(return_value=True)
        return svc

    async def test_holds_all_containers_when_not_synced(self):
        svc = self._svc()
        with patch.object(ds_mod, "SYNC_GATE_CONTAINERS", ["p2pool", "xmrig-proxy"]):
            await svc._apply_sync_gate(gate_satisfied=False)
        stopped = {c.args[0] for c in svc.docker_control.stop.await_args_list}
        assert stopped == {"p2pool", "xmrig-proxy"}
        svc.docker_control.start.assert_not_called()
        assert svc.miner_held is True
        assert svc.miner_released is False

    async def test_releases_when_gate_satisfied(self):
        svc = self._svc()
        with patch.object(ds_mod, "SYNC_GATE_CONTAINERS", ["p2pool", "xmrig-proxy"]):
            await svc._apply_sync_gate(gate_satisfied=True)
        started = {c.args[0] for c in svc.docker_control.start.await_args_list}
        assert started == {"p2pool", "xmrig-proxy"}
        svc.docker_control.stop.assert_not_called()
        assert svc.miner_released is True
        assert svc.miner_held is False

    async def test_noop_once_released(self):
        # One-way latch: after release we never touch the containers again, so a later
        # not-synced reading (e.g. a node blip) can't fight #31 by re-stopping the miner.
        svc = self._svc()
        svc.miner_released = True
        await svc._apply_sync_gate(gate_satisfied=False)
        await svc._apply_sync_gate(gate_satisfied=True)
        svc.docker_control.stop.assert_not_called()
        svc.docker_control.start.assert_not_called()

    async def test_release_survives_an_unremovable_restore_marker(self, tmp_path, caplog):
        # #2626: failing to retire the marker is logged; the release on this machine stands.
        svc = self._svc()
        with (
            patch.object(ds_mod, "SYNC_GATE_RESET_PATH", str(tmp_path)),  # a dir: remove fails
            patch.object(ds_mod, "SYNC_GATE_CONTAINERS", ["p2pool"]),
        ):
            await svc._apply_sync_gate(gate_satisfied=True)
        assert svc.miner_released is True
        assert "Could not remove the restore's sync-gate marker" in caplog.text

    async def test_partial_start_failure_keeps_latch_closed(self):
        # If only one container starts, stay unreleased so the next cycle retries the rest.
        svc = self._svc()
        svc.docker_control.start = AsyncMock(side_effect=[True, False])
        with patch.object(ds_mod, "SYNC_GATE_CONTAINERS", ["p2pool", "xmrig-proxy"]):
            await svc._apply_sync_gate(gate_satisfied=True)
        assert svc.miner_released is False

    async def test_rehold_stops_quietly_after_first_cycle(self):
        # The first hold logs (quiet=False); subsequent re-asserts are quiet so a multi-hour
        # sync doesn't flood the dashboard log.
        svc = self._svc()
        with patch.object(ds_mod, "SYNC_GATE_CONTAINERS", ["p2pool"]):
            await svc._apply_sync_gate(gate_satisfied=False)
            await svc._apply_sync_gate(gate_satisfied=False)
        first, second = svc.docker_control.stop.await_args_list
        assert first.kwargs.get("quiet") is False
        assert second.kwargs.get("quiet") is True


# monerod's get_info right after a restart, before any peer has told it the network height:
# target_height 0 with synchronized false. MoneroClient maps target 0 to "not syncing" (#2472).
_PEERLESS_RESTART = {"status": "OK", "height": 5, "target_height": 0, "synchronized": False}
_SYNCED = {"status": "OK", "height": 800000, "target_height": 0, "synchronized": True}
_TARI_SYNCED = {"is_syncing": False, "reachable": True}


class _PastTheGate(BaseException):
    """Raised from a step after the gate to end one loop iteration."""


def _restored(sm):
    """A recreated dashboard: a fresh DataService restoring the snapshot ``sm`` last saved."""
    svc, new_sm, _ = _make_service()
    new_sm.load_snapshot.return_value = json.loads(json.dumps(sm.save_snapshot.call_args.args[0]))
    restored = DataService(new_sm, MagicMock(), MagicMock())
    restored.docker_control = svc.docker_control
    return restored


class TestSyncGateDecision:
    """The loop's sync-result-to-gate decision, from the real Monero RPC mapping onward (#2472)."""

    async def _iterate(self, svc, tari_sync, get_info=None, monero_sync=None, tari_required=True):
        """Run one loop iteration. With ``get_info`` the real local-monerod path
        (MoneroClient.get_sync_status -> _get_local_monero_sync_status) produces the reading;
        with ``monero_sync`` that dict is served as the reading itself."""
        # End the iteration at the Tor healer, past the gate and the snapshot save. A
        # BaseException skips the loop's `except Exception`, so reaching it proves nothing earlier
        # in the body raised and skipped the gate.
        svc.tor_healer.check = AsyncMock(side_effect=_PastTheGate)
        worker_client = MagicMock()
        worker_client.get_stats = AsyncMock(return_value={})
        tari_client = MagicMock()
        tari_client.get_sync_status = AsyncMock(return_value=tari_sync)
        if monero_sync is not None:
            monero_patch = patch.object(
                ds_mod, "get_monero_sync_status", AsyncMock(return_value=monero_sync)
            )
        else:
            monero_patch = patch.object(logs_mod._monero_client, "get_info", return_value=get_info)
        with (
            monero_patch,
            patch.object(logs_mod, "MONERO_NODE_HOST", logs_mod.LOCAL_MONERO_HOST),
            patch.object(ds_mod, "ClientSession", _FakeClientSession),
            patch.object(ds_mod, "XMRigWorkerClient", return_value=worker_client),
            patch.object(ds_mod, "TariClient", return_value=tari_client),
            patch.object(ds_mod, "SYNC_GATE_CONTAINERS", ["p2pool", "xmrig-proxy"]),
            patch.object(ds_mod, "TARI_REQUIRED", tari_required),
            patch.object(ds_mod, "get_stratum_stats", return_value={}),
            patch.object(ds_mod, "get_network_stats", return_value={"height": 0}),
            patch.object(ds_mod, "get_tari_stats", return_value={"active": False, "height": 0}),
            patch.object(
                ds_mod,
                "get_p2pool_stats",
                return_value={"pool": {"last_share_time": 0, "difficulty": 0}},
            ),
            patch.object(ds_mod, "get_disk_usage", return_value={}),
            patch.object(ds_mod, "get_hugepages_status", return_value=("Enabled", "ok", "1/2")),
            patch.object(ds_mod, "get_memory_usage", return_value={}),
            patch.object(ds_mod, "get_load_average", return_value="0"),
            patch.object(ds_mod, "get_cpu_usage", return_value="0%"),
            patch.object(ds_mod, "get_cpu_avx2", return_value=True),
            patch("asyncio.sleep", AsyncMock(side_effect=StopAsyncIteration)),
        ):
            with pytest.raises(_PastTheGate):
                await svc.run()

    async def test_peerless_restart_does_not_release_or_persist_the_latch(self, caplog):
        # Job 722's shape: Tari off (non-blocking), monerod just restarted with no peers yet.
        svc, sm, proxy = _make_service()
        proxy.get_workers.return_value = {"workers": []}
        await self._iterate(svc, _TARI_SYNCED, get_info=_PEERLESS_RESTART, tari_required=False)
        svc.docker_control.start.assert_not_called()
        assert svc.miner_released is False
        assert sm.save_snapshot.call_args.args[0]["miner_released"] is False

        # The recreated dashboard restores the held state and re-asserts the hold, notice included.
        restarted = _restored(sm)
        restarted.docker_control.stop.reset_mock()
        caplog.set_level("INFO", logger="DataService")
        await self._iterate(
            restarted, _TARI_SYNCED, get_info=_PEERLESS_RESTART, tari_required=False
        )
        assert restarted.miner_released is False
        stops = restarted.docker_control.stop.await_args_list
        assert {c.args[0] for c in stops} == {"p2pool", "xmrig-proxy"}
        assert stops[0].kwargs.get("quiet") is False
        assert "still syncing — holding p2pool, xmrig-proxy" in caplog.text

    async def test_synchronized_monerod_releases_and_the_latch_survives_restart(self):
        svc, sm, proxy = _make_service()
        proxy.get_workers.return_value = {"workers": []}
        await self._iterate(svc, _TARI_SYNCED, get_info=_SYNCED)
        assert {c.args[0] for c in svc.docker_control.start.await_args_list} == {
            "p2pool",
            "xmrig-proxy",
        }
        assert sm.save_snapshot.call_args.args[0]["miner_released"] is True

        # Post-sync one-way latch: a restart restores the release and a later blip never re-holds.
        restarted = _restored(sm)
        restarted.docker_control.stop.reset_mock()
        assert restarted.miner_released is True
        await self._iterate(restarted, _TARI_SYNCED, get_info=_PEERLESS_RESTART)
        stopped = {c.args[0] for c in restarted.docker_control.stop.await_args_list}
        assert "p2pool" not in stopped
        assert restarted.miner_released is True

    async def test_restore_marker_re_derives_a_carried_release(self, tmp_path, monkeypatch):
        # #2626: a released source machine's snapshot restored onto hardware whose monerod has not
        # synced. The restore's marker overrides the carried latch until the gate releases here.
        svc, sm, proxy = _make_service()
        proxy.get_workers.return_value = {"workers": []}
        await self._iterate(svc, _TARI_SYNCED, get_info=_SYNCED)
        assert sm.save_snapshot.call_args.args[0]["miner_released"] is True

        marker = tmp_path / "sync-gate-reset"
        marker.touch()
        monkeypatch.setattr(ds_mod, "SYNC_GATE_RESET_PATH", str(marker))
        restored = _restored(sm)
        assert restored.miner_released is False
        await self._iterate(restored, _TARI_SYNCED, get_info=_PEERLESS_RESTART)
        stopped = {c.args[0] for c in restored.docker_control.stop.await_args_list}
        assert stopped == {"p2pool", "xmrig-proxy"}
        restored.docker_control.start.assert_not_called()
        assert marker.exists()

        # Synced here: the gate releases on this machine's own chains and retires the marker.
        await self._iterate(restored, _TARI_SYNCED, get_info=_SYNCED)
        assert restored.miner_released is True
        assert not marker.exists()
        assert _restored(restored.state_manager).miner_released is True

    @pytest.mark.parametrize(
        ("monero_sync", "tari_sync"),
        [
            ({}, _TARI_SYNCED),  # empty Monero result
            ({"is_syncing": False}, _TARI_SYNCED),  # partial: no reachability verdict
            ({"is_syncing": False, "reachable": False}, _TARI_SYNCED),  # unreachable
            ({"reachable": True}, _TARI_SYNCED),  # partial: no syncing verdict
            ({"is_syncing": False, "reachable": True}, {}),  # empty required-Tari result
            ({"is_syncing": False, "reachable": True}, {"is_syncing": False}),  # partial Tari
        ],
    )
    async def test_absent_or_partial_results_hold(self, monero_sync, tari_sync):
        svc, sm, proxy = _make_service()
        proxy.get_workers.return_value = {"workers": []}
        await self._iterate(svc, tari_sync, monero_sync=monero_sync)
        svc.docker_control.start.assert_not_called()
        assert sm.save_snapshot.call_args.args[0]["miner_released"] is False

    async def test_unreachable_rpc_with_a_synced_log_line_holds(self):
        # RPC down, old container logs still say "synchronized": the log fallback is display-only.
        svc, sm, proxy = _make_service()
        proxy.get_workers.return_value = {"workers": []}
        with patch.object(
            logs_mod, "get_monero_logs", AsyncMock(return_value=["You are now synchronized"])
        ):
            await self._iterate(svc, _TARI_SYNCED, get_info=None)
        svc.docker_control.start.assert_not_called()
        assert svc.miner_released is False
