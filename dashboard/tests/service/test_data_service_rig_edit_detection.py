# ruff: noqa: F403, F405
from tests.service._data_service_support import *  # noqa: F403


class TestRigEditDetection:
    """#530: a rig's control-status mirror reports a TERMINAL outcome for a change_id this
    dashboard never spooled into ``worker_config`` — the rig applied it on its own. That gets
    recorded as a ``rig-edit`` audit row naming the worker, instead of the silent no-op a
    ``reconcile_worker_config_status`` UPDATE would be against a change_id with no matching row."""

    def _svc_with_real_storage(self):
        from mining_dashboard.service.storage_service import StateManager

        sm = StateManager(db_path=":memory:")
        svc = DataService(sm, MagicMock(), MagicMock())
        return svc, sm

    def test_unknown_change_id_records_rig_edit(self):
        svc, sm = self._svc_with_real_storage()
        try:
            worker_results = [
                {
                    "rigforge": {
                        "control": {
                            "change_id": "rig-local-cid",
                            "status": "applied",
                            "reason": None,
                        }
                    }
                }
            ]
            asyncio.run(svc._reconcile_worker_config([{"name": "rig1"}], worker_results))
            events = sm.get_audit_events()
            assert len(events) == 1
            assert events[0]["source"] == "rig-edit"
            assert events[0]["actor"] == "rig1"
            assert events[0]["status"] == "applied"
            assert "rig-local-cid" in events[0]["keys"]
            # Nothing to reconcile — no #185 row existed for this change_id.
            assert sm.get_worker_config_history("rig1") == []
        finally:
            sm.close()

    def test_known_change_id_never_flagged(self):
        svc, sm = self._svc_with_real_storage()
        try:
            sm.add_worker_config_version("rig1", "cid-1", "accepted", {"max_temp_c": 80}, None)
            worker_results = [
                {"rigforge": {"control": {"change_id": "cid-1", "status": "applied"}}}
            ]
            asyncio.run(svc._reconcile_worker_config([{"name": "rig1"}], worker_results))
            assert sm.get_audit_events() == []
        finally:
            sm.close()

    def test_multiple_workers_only_the_unknown_one_flagged(self):
        svc, sm = self._svc_with_real_storage()
        try:
            sm.add_worker_config_version("rig1", "cid-known", "accepted", {}, None)
            worker_results = [
                {"rigforge": {"control": {"change_id": "cid-known", "status": "applied"}}},
                {"rigforge": {"control": {"change_id": "cid-unknown", "status": "rejected"}}},
            ]
            asyncio.run(
                svc._reconcile_worker_config([{"name": "rig1"}, {"name": "rig2"}], worker_results)
            )
            events = sm.get_audit_events()
            assert len(events) == 1
            assert events[0]["actor"] == "rig2"
            assert events[0]["status"] == "rejected"
        finally:
            sm.close()

    def test_same_change_id_across_polls_records_exactly_one_row(self):
        # The flood guard (HIGH #530 review): a rig re-reports its last terminal change_id every
        # poll. Deterministic row id + in-memory guard must collapse that to ONE audit row, not a
        # new row per ~30s cycle for a permanent, never-pruned table.
        svc, sm = self._svc_with_real_storage()
        try:
            worker_results = [
                {"rigforge": {"control": {"change_id": "rig-local-cid", "status": "applied"}}}
            ]
            for _ in range(3):  # three consecutive polls, same report
                asyncio.run(svc._reconcile_worker_config([{"name": "rig1"}], worker_results))
            assert len(sm.get_audit_events()) == 1
        finally:
            sm.close()

    def test_repeat_report_after_a_restart_still_dedups_via_the_deterministic_id(self):
        # The in-memory guard is empty on a fresh DataService (restart), but the SAME rig report
        # must still not duplicate the row — the deterministic id + INSERT OR IGNORE is the bound.
        from mining_dashboard.service.storage_service import StateManager

        sm = StateManager(db_path=":memory:")
        try:
            worker_results = [
                {"rigforge": {"control": {"change_id": "rig-local-cid", "status": "applied"}}}
            ]
            svc1 = DataService(sm, MagicMock(), MagicMock())
            asyncio.run(svc1._reconcile_worker_config([{"name": "rig1"}], worker_results))
            svc2 = DataService(sm, MagicMock(), MagicMock())  # "restart": fresh empty guard set
            asyncio.run(svc2._reconcile_worker_config([{"name": "rig1"}], worker_results))
            assert len(sm.get_audit_events()) == 1
        finally:
            sm.close()

    def _flood(self, svc, worker, change_ids):
        for cid in change_ids:
            wr = [{"rigforge": {"control": {"change_id": cid, "status": "applied"}}}]
            asyncio.run(svc._reconcile_worker_config([{"name": worker}], wr))

    def test_distinct_change_id_flood_is_bounded_per_worker(self):
        # #724: a rogue rig on the unauthenticated feed reports a NEW change_id every poll. Each
        # clears #530's deterministic-id dedup, so without a cap every poll writes a permanent row.
        # The per-worker hourly cap bounds rig-edit rows to _RIG_EDIT_CAP_PER_HOUR, plus exactly one
        # rate-limited marker so the flood stays visible — not silently swallowed.
        svc, sm = self._svc_with_real_storage()
        try:
            cap = ds_mod._RIG_EDIT_CAP_PER_HOUR
            self._flood(svc, "rig1", [f"cid-{i}" for i in range(cap + 8)])
            events = sm.get_audit_events()
            rig_edits = [e for e in events if e["action"] == "rig-edit"]
            markers = [e for e in events if e["action"] == "rate-limited"]
            assert len(rig_edits) == cap
            assert len(markers) == 1
            assert markers[0]["source"] == "rig-edit"
            assert markers[0]["actor"] == "rig1"
            assert markers[0]["status"] == "dropped"
        finally:
            sm.close()

    def test_normal_cadence_is_never_rate_limited(self):
        # A real operator edits a rig a handful of times an hour — well under the cap. Every genuine
        # change_id records and no rate-limited marker is ever written.
        svc, sm = self._svc_with_real_storage()
        try:
            self._flood(svc, "rig1", ["real-0", "real-1", "real-2"])
            events = sm.get_audit_events()
            assert len(events) == 3
            assert all(e["action"] == "rig-edit" for e in events)
        finally:
            sm.close()

    def test_cap_is_per_worker_a_flood_does_not_starve_another_rig(self):
        # The cap is keyed on the worker (not global), so one rogue rig flooding distinct change_ids
        # never drops a genuine rig-edit — nor any host-edit — from a different, well-behaved source.
        svc, sm = self._svc_with_real_storage()
        try:
            self._flood(
                svc, "rogue", [f"flood-{i}" for i in range(ds_mod._RIG_EDIT_CAP_PER_HOUR + 5)]
            )
            self._flood(svc, "goodrig", ["honest-cid"])
            goodrig = [e for e in sm.get_audit_events() if e["actor"] == "goodrig"]
            assert len(goodrig) == 1
            assert goodrig[0]["action"] == "rig-edit"
        finally:
            sm.close()

    def test_cap_resets_after_the_window_elapses(self, monkeypatch):
        # Fixed in-memory window: once an hour passes the worker's budget refreshes, so a later
        # genuine change_id records normally again — the cap throttles a flood, it doesn't ban a rig.
        svc, sm = self._svc_with_real_storage()
        clock = {"t": 1000.0}
        monkeypatch.setattr(ds_mod.time, "time", lambda: clock["t"])
        try:
            cap = ds_mod._RIG_EDIT_CAP_PER_HOUR
            self._flood(svc, "rig1", [f"cid-{i}" for i in range(cap + 3)])
            assert len([e for e in sm.get_audit_events() if e["action"] == "rig-edit"]) == cap
            clock["t"] += ds_mod._RIG_EDIT_WINDOW_SEC + 1  # next window
            self._flood(svc, "rig1", ["post-window"])
            assert [e for e in sm.get_audit_events() if "post-window" in e["keys"]]
        finally:
            sm.close()
