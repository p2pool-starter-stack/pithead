# ruff: noqa: F403, F405
from tests.service._data_service_support import *  # noqa: F403


class TestReconcileWorkerConfig:
    """#579: the dashboard's regular per-rig read poll reconciles any #185 history row a slow rig
    rollback left stuck 'accepted', once the rig's enriched feed mirrors a terminal outcome for
    that change_id (rigforge.control). Real StateManager (not a mock) throughout — every assertion
    reads back the actual stored row, so a reverted WHERE-clause guard or a dropped reconcile call
    fails these tests, not just a mock's call count.

    #530 extends the same poll: a TERMINAL report for a change_id this dashboard never spooled is
    a rig-side out-of-band edit, recorded to ``audit_events`` instead of silently reconciling
    nothing."""

    def _svc_with_real_storage(self):
        from mining_dashboard.service.storage_service import StateManager

        sm = StateManager(db_path=":memory:")
        svc = DataService(sm, MagicMock(), MagicMock())
        return svc, sm

    def _seed(self, sm, status, change_id="cid-1", worker="rig1"):
        sm.add_worker_config_version(worker, change_id, status, {"max_temp_c": 80}, None)

    def _status_of(self, sm, worker="rig1", change_id="cid-1"):
        rows = [r for r in sm.get_worker_config_history(worker) if r["change_id"] == change_id]
        assert len(rows) == 1
        return rows[0]

    def _workers(self, *names):
        return [{"name": n} for n in names]

    def test_terminal_report_reconciles_accepted_row(self):
        # The main revert-proof case: a real 'accepted' row becomes 'rolled_back' once the rig's
        # enriched feed mirrors that outcome for the matching change_id.
        svc, sm = self._svc_with_real_storage()
        try:
            self._seed(sm, "accepted")
            worker_results = [
                {
                    "rigforge": {
                        "control": {
                            "change_id": "cid-1",
                            "status": "rolled_back",
                            "reason": "miner did not return to a live hashrate",
                        }
                    }
                }
            ]
            asyncio.run(svc._reconcile_worker_config(self._workers("rig1"), worker_results))
            row = self._status_of(sm)
            assert row["status"] == "rolled_back"
            assert row["reason"] == "miner did not return to a live hashrate"
            # A known change_id reconciles quietly — no audit row for the dashboard's own change.
            assert sm.get_audit_events() == []
        finally:
            sm.close()

    def test_terminal_report_reconciles_accepted_row_for_the_1009_vocabulary(self):
        # #1009: failed/noop/throttled (rigforge#320) must reach the SAME reconcile path as
        # applied/rejected/rolled_back — the mirror now ships live (rigforge v1.15.0, #346), and
        # the pre-#1009 three-status allowlist dropped exactly these on the floor as "accepted"
        # forever.
        svc, sm = self._svc_with_real_storage()
        try:
            for status in ("failed", "noop", "throttled"):
                cid = f"cid-{status}"
                self._seed(sm, "accepted", change_id=cid)
                worker_results = [
                    {
                        "rigforge": {
                            "control": {
                                "change_id": cid,
                                "status": status,
                                "reason": "rig-supplied",
                            }
                        }
                    }
                ]
                asyncio.run(svc._reconcile_worker_config(self._workers("rig1"), worker_results))
                row = self._status_of(sm, change_id=cid)
                assert row["status"] == status
                assert row["reason"] == "rig-supplied"
        finally:
            sm.close()

    def test_terminal_row_is_never_overwritten(self):
        svc, sm = self._svc_with_real_storage()
        try:
            self._seed(sm, "applied")
            worker_results = [
                {"rigforge": {"control": {"change_id": "cid-1", "status": "rolled_back"}}}
            ]
            asyncio.run(svc._reconcile_worker_config(self._workers("rig1"), worker_results))
            assert self._status_of(sm)["status"] == "applied"
        finally:
            sm.close()

    def test_offline_rig_leaves_row_accepted(self):
        # An unreachable/offline rig probes to {} (XMRigWorkerClient.get_stats' failure shape) — no
        # false terminal.
        svc, sm = self._svc_with_real_storage()
        try:
            self._seed(sm, "accepted")
            asyncio.run(svc._reconcile_worker_config(self._workers("rig1"), [{}]))
            assert self._status_of(sm)["status"] == "accepted"
        finally:
            sm.close()

    def test_missing_change_id_leaves_row_accepted(self):
        svc, sm = self._svc_with_real_storage()
        try:
            self._seed(sm, "accepted")
            worker_results = [{"rigforge": {"control": {"status": "rolled_back"}}}]
            asyncio.run(svc._reconcile_worker_config(self._workers("rig1"), worker_results))
            assert self._status_of(sm)["status"] == "accepted"
        finally:
            sm.close()

    def test_still_in_flight_report_leaves_row_accepted(self):
        svc, sm = self._svc_with_real_storage()
        try:
            self._seed(sm, "accepted")
            worker_results = [
                {"rigforge": {"control": {"change_id": "cid-1", "status": "accepted"}}}
            ]
            asyncio.run(svc._reconcile_worker_config(self._workers("rig1"), worker_results))
            assert self._status_of(sm)["status"] == "accepted"
        finally:
            sm.close()

    def test_superseded_change_reconciles_from_control_history(self):
        # #1702: change A applies, then change B applies on the SAME rig before the dashboard's
        # next poll. `rigforge.control` (the single-slot mirror) now names only B — without the
        # rigforge#519 ring, row A would stay 'accepted' forever. Both terminate inside one poll.
        svc, sm = self._svc_with_real_storage()
        try:
            self._seed(sm, "accepted", change_id="cid-a")
            self._seed(sm, "accepted", change_id="cid-b")
            worker_results = [
                {
                    "rigforge": {
                        "control": {"change_id": "cid-b", "status": "applied"},
                        "control_history": [
                            {"change_id": "cid-a", "status": "applied", "reason": None},
                            {"change_id": "cid-b", "status": "applied", "reason": None},
                        ],
                    }
                }
            ]
            asyncio.run(svc._reconcile_worker_config(self._workers("rig1"), worker_results))
            assert self._status_of(sm, change_id="cid-a")["status"] == "applied"
            assert self._status_of(sm, change_id="cid-b")["status"] == "applied"
            # Both change_ids are the dashboard's own — no rig-edit row for either.
            assert sm.get_audit_events() == []
        finally:
            sm.close()

    def test_unknown_control_history_entry_is_not_flagged_rig_edit(self):
        # History reconciles existing rows; only `control` (the current slot) creates rig-edit
        # events for changes this dashboard never spooled.
        svc, sm = self._svc_with_real_storage()
        try:
            worker_results = [
                {
                    "rigforge": {
                        "control": None,
                        "control_history": [
                            {"change_id": "cid-unknown", "status": "applied", "reason": None}
                        ],
                    }
                }
            ]
            asyncio.run(svc._reconcile_worker_config(self._workers("rig1"), worker_results))
            assert sm.get_audit_events() == []
        finally:
            sm.close()

    def test_malformed_control_history_entry_is_skipped(self):
        svc, sm = self._svc_with_real_storage()
        try:
            self._seed(sm, "accepted")
            worker_results = [
                {
                    "rigforge": {
                        "control_history": [
                            None,
                            {"change_id": "cid-1", "status": "applied", "reason": None},
                        ]
                    }
                }
            ]
            asyncio.run(svc._reconcile_worker_config(self._workers("rig1"), worker_results))
            assert self._status_of(sm)["status"] == "applied"
        finally:
            sm.close()

    def test_control_history_stops_at_producer_limit(self):
        svc, sm = self._svc_with_real_storage()
        try:
            self._seed(sm, "accepted", change_id="cid-in")
            self._seed(sm, "accepted", change_id="cid-over")
            sm.worker_config_change_known = MagicMock(wraps=sm.worker_config_change_known)
            sm.reconcile_worker_config_status = MagicMock(wraps=sm.reconcile_worker_config_status)
            duplicate = {"change_id": "cid-in", "status": "applied", "reason": None}
            over = {"change_id": "cid-over", "status": "applied", "reason": None}
            worker_results = [
                {"rigforge": {"control_history": [None] * 10 + [duplicate] * 10 + [over]}}
            ]
            asyncio.run(svc._reconcile_worker_config(self._workers("rig1"), worker_results))
            assert sm.worker_config_change_known.call_count == 10
            assert sm.reconcile_worker_config_status.call_count == 10
            assert self._status_of(sm, change_id="cid-in")["status"] == "applied"
            assert self._status_of(sm, change_id="cid-over")["status"] == "accepted"
        finally:
            sm.close()

    def test_multiple_workers_reconciled_independently(self):
        svc, sm = self._svc_with_real_storage()
        try:
            self._seed(sm, "accepted", change_id="cid-1", worker="rig1")
            self._seed(sm, "accepted", change_id="cid-2", worker="rig2")
            worker_results = [
                {"rigforge": {"control": {"change_id": "cid-1", "status": "applied"}}},
                {
                    "rigforge": {
                        "control": {
                            "change_id": "cid-2",
                            "status": "rejected",
                            "reason": "bad pool url",
                        }
                    }
                },
            ]
            asyncio.run(svc._reconcile_worker_config(self._workers("rig1", "rig2"), worker_results))
            assert self._status_of(sm, worker="rig1", change_id="cid-1")["status"] == "applied"
            row2 = self._status_of(sm, worker="rig2", change_id="cid-2")
            assert row2["status"] == "rejected"
            assert row2["reason"] == "bad pool url"
        finally:
            sm.close()
