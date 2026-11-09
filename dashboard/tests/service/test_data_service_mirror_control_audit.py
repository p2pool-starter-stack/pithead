# ruff: noqa: F403, F405
from tests.service._data_service_support import *  # noqa: F403


class TestMirrorControlAudit:
    """#530: opportunistically copies the #33 log's recent entries into the durable
    ``audit_events`` table so the Security panel can group deeper than the log's own trimmed
    tail. ``audit_service.recent_changes()`` output is already sanitized — nothing new to clean
    here, only to persist."""

    def _svc(self):
        from mining_dashboard.service.storage_service import StateManager

        sm = StateManager(db_path=":memory:")
        svc = DataService(sm, MagicMock(), MagicMock())
        return svc, sm

    def _log_line(self, **over):
        entry = {
            "ts": "2026-07-10T12:00:00Z",
            "id": "11111111-1111-4111-8111-111111111111",
            "actor": "admin",
            "action": "commit",
            "status": "applied",
            "keys": "XVB_ENABLED",
        }
        entry.update(over)
        return json.dumps(entry)

    async def test_disabled_is_a_noop(self, monkeypatch):
        monkeypatch.setattr(ds_mod.config, "DASHBOARD_CONTROL_ENABLED", False)
        svc, sm = self._svc()
        try:
            await svc._mirror_control_audit()
            assert sm.get_audit_events() == []
        finally:
            sm.close()

    async def test_mirrors_log_entries(self, tmp_path, monkeypatch):
        log = tmp_path / "control.log"
        log.write_text(self._log_line() + "\n")
        monkeypatch.setattr(ds_mod.config, "DASHBOARD_CONTROL_ENABLED", True)
        monkeypatch.setattr(ds_mod.audit_service.config, "CONTROL_AUDIT_LOG", str(log))
        svc, sm = self._svc()
        try:
            await svc._mirror_control_audit()
            events = sm.get_audit_events()
            assert len(events) == 1
            assert events[0]["source"] == "control"
            assert events[0]["actor"] == "admin"
            assert events[0]["keys"] == "XVB_ENABLED"
        finally:
            sm.close()

    async def test_re_mirroring_is_idempotent(self, tmp_path, monkeypatch):
        log = tmp_path / "control.log"
        log.write_text(self._log_line() + "\n")
        monkeypatch.setattr(ds_mod.config, "DASHBOARD_CONTROL_ENABLED", True)
        monkeypatch.setattr(ds_mod.audit_service.config, "CONTROL_AUDIT_LOG", str(log))
        svc, sm = self._svc()
        try:
            await svc._mirror_control_audit()
            await svc._mirror_control_audit()
            assert len(sm.get_audit_events()) == 1
        finally:
            sm.close()

    async def test_entries_without_an_id_are_skipped(self, tmp_path, monkeypatch):
        log = tmp_path / "control.log"
        log.write_text(self._log_line(id="") + "\n")
        monkeypatch.setattr(ds_mod.config, "DASHBOARD_CONTROL_ENABLED", True)
        monkeypatch.setattr(ds_mod.audit_service.config, "CONTROL_AUDIT_LOG", str(log))
        svc, sm = self._svc()
        try:
            await svc._mirror_control_audit()
            assert sm.get_audit_events() == []
        finally:
            sm.close()

    async def test_fleet_update_all_children_stay_distinct_after_reopen(
        self, tmp_path, monkeypatch
    ):
        from pathlib import Path

        from mining_dashboard.service.storage_service import StateManager
        from mining_dashboard.web.server import _merged_audit_entries

        fixture = Path(__file__).parent / "fixtures" / "worker-upgrade-all-control.jsonl"
        now = time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())
        log = tmp_path / "control.log"
        log.write_text(fixture.read_text().replace("2026-01-01T00:00:00Z", now))
        parent = "45454545-4545-4545-9545-454545454545"
        outcomes = ["applied", "failed", "rejected", "rejected", "noop"]
        expected = {parent: ("worker-upgrade-all", "completed")} | {
            f"{parent}-{i}": ("worker-upgrade", s) for i, s in enumerate(outcomes)
        }
        monkeypatch.setattr(ds_mod.config, "DASHBOARD_CONTROL_ENABLED", True)
        monkeypatch.setattr(ds_mod.audit_service.config, "CONTROL_AUDIT_LOG", str(log))
        db = str(tmp_path / "state.db")
        sm = StateManager(db_path=db)
        await DataService(sm, MagicMock(), MagicMock())._mirror_control_audit()
        sm.close()
        monkeypatch.setattr(
            ds_mod.audit_service.config, "CONTROL_AUDIT_LOG", str(tmp_path / "rotated.log")
        )
        sm = StateManager(db_path=db)
        try:
            durable = {e["id"]: (e["action"], e["status"]) for e in sm.get_audit_events()}
            merged = {e["id"]: (e["action"], e["status"]) for e in _merged_audit_entries(sm)}
            assert durable == expected
            assert merged == expected
        finally:
            sm.close()
