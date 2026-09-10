# ruff: noqa: F403, F405
from tests.service._data_service_support import *  # noqa: F403


class TestInit:
    def test_restores_snapshot(self):
        sm = MagicMock()
        sm.load_snapshot.return_value = {"total_live_h15": 5000, "extra": "kept"}
        svc = DataService(sm, MagicMock(), MagicMock())
        assert svc.latest_data["total_live_h15"] == 5000
        assert svc.latest_data["extra"] == "kept"

    def test_restored_snapshot_never_resurrects_the_update_badge(self):
        # #664: `update` is derived state — a pre-upgrade "new release available" restored after
        # the very upgrade it advertised must be dropped; the checker recomputes on its cadence.
        sm = MagicMock()
        sm.load_snapshot.return_value = {
            "total_live_h15": 5000,
            "update": {"available": True, "latest": "v1.9.1", "url": "u"},
            # #596: same rule for the fleet-wide RigForge release — restored with the flag now
            # off, it would keep serving stale per-worker badges until the first poll cycle.
            "rigforge_release": {"tag": "v1.11.2", "url": "u"},
        }
        svc = DataService(sm, MagicMock(), MagicMock())
        assert svc.latest_data.get("update") in (None, {})  # never the restored dict
        assert svc.latest_data.get("rigforge_release") is None  # nor the RigForge one (#596)
        assert svc.latest_data["total_live_h15"] == 5000  # the rest of the snapshot survives

    def test_rigforge_checker_wired_to_the_rigforge_api_under_the_same_flag(self):
        # #596 wiring: one fleet-wide RigForge release checker, pointed at the RigForge repo,
        # gated on the SAME dashboard.check_for_updates flag as the stack's own check.
        sm = MagicMock()
        sm.load_snapshot.return_value = None
        svc = DataService(sm, MagicMock(), MagicMock())
        assert svc.rigforge_update_checker.client.api_url == ds_mod.GITHUB_RIGFORGE_RELEASES_API
        assert "rigforge" in svc.rigforge_update_checker.client.api_url
        assert svc.rigforge_update_checker.enabled == svc.update_checker.enabled
        assert svc.rigforge_update_checker.client.tor_proxy == svc.update_checker.client.tor_proxy

    def test_ignores_non_dict_snapshot(self):
        sm = MagicMock()
        sm.load_snapshot.return_value = None
        svc = DataService(sm, MagicMock(), MagicMock())
        assert svc.latest_data["total_live_h15"] == 0

    def test_restores_workers_rejected_flag(self):
        # A dashboard restart mid-outage must remember it had rejected workers, so it can
        # readmit them on recovery (Issue #31).
        sm = MagicMock()
        sm.load_snapshot.return_value = {"workers_rejected": True}
        svc = DataService(sm, MagicMock(), MagicMock())
        assert svc.workers_rejected is True

    def test_restores_miner_released_latch(self):
        # A restart after the miner was released must NOT re-hold a running, mining stack (#35).
        sm = MagicMock()
        sm.load_snapshot.return_value = {"miner_released": True}
        svc = DataService(sm, MagicMock(), MagicMock())
        assert svc.miner_released is True

    def test_holds_miner_when_restart_mid_sync(self):
        # Fresh state (no snapshot) → the miner is held until the gate is first satisfied.
        sm = MagicMock()
        sm.load_snapshot.return_value = None
        svc = DataService(sm, MagicMock(), MagicMock())
        assert svc.miner_released is False
