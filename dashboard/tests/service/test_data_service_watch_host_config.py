# ruff: noqa: F403, F405
from tests.service._data_service_support import *  # noqa: F403


class TestWatchHostConfig:
    """#530: config.json changed without a matching control-channel commit -> a ``host-edit``
    audit row. Real StateManager throughout, like TestReconcileWorkerConfig — every assertion
    reads back the persisted row."""

    def _svc(self):
        from mining_dashboard.service.storage_service import StateManager

        sm = StateManager(db_path=":memory:")
        svc = DataService(sm, MagicMock(), MagicMock())
        return svc, sm

    def _write_config(self, path, doc):
        path.write_text(json.dumps(doc))

    async def test_control_disabled_is_a_noop(self, monkeypatch):
        monkeypatch.setattr(ds_mod.config, "DASHBOARD_CONTROL_ENABLED", False)
        svc, sm = self._svc()
        try:
            await svc._watch_host_config()
            assert sm.get_audit_events() == []
            assert svc._last_host_config is None
        finally:
            sm.close()

    async def test_first_poll_only_baselines(self, tmp_path, monkeypatch):
        cfg = tmp_path / "config.json"
        self._write_config(cfg, {"xvb": {"enabled": True}})
        monkeypatch.setattr(ds_mod.config, "DASHBOARD_CONTROL_ENABLED", True)
        monkeypatch.setattr(ds_mod.config, "HOST_CONFIG_PATH", str(cfg))
        svc, sm = self._svc()
        try:
            await svc._watch_host_config()
            assert sm.get_audit_events() == []
            assert svc._last_host_config == {"xvb": {"enabled": True}}
        finally:
            sm.close()

    async def test_unexplained_change_is_recorded_host_edit(self, tmp_path, monkeypatch):
        cfg, log = tmp_path / "config.json", tmp_path / "control.log"
        self._write_config(cfg, {"xvb": {"enabled": True}})
        monkeypatch.setattr(ds_mod.config, "DASHBOARD_CONTROL_ENABLED", True)
        monkeypatch.setattr(ds_mod.config, "HOST_CONFIG_PATH", str(cfg))
        monkeypatch.setattr(ds_mod.audit_service.config, "CONTROL_AUDIT_LOG", str(log))
        svc, sm = self._svc()
        try:
            await svc._watch_host_config()  # baseline
            self._write_config(cfg, {"xvb": {"enabled": False}})  # changed out of band
            await svc._watch_host_config()
            events = sm.get_audit_events()
            assert len(events) == 1
            assert events[0]["source"] == "host-edit"
            assert events[0]["keys"] == "xvb.enabled"
            assert events[0]["status"] == "detected"
        finally:
            sm.close()

    async def test_change_explained_by_a_fresh_commit_is_quiet(self, tmp_path, monkeypatch):
        cfg, log = tmp_path / "config.json", tmp_path / "control.log"
        self._write_config(cfg, {"xvb": {"enabled": True}})
        monkeypatch.setattr(ds_mod.config, "DASHBOARD_CONTROL_ENABLED", True)
        monkeypatch.setattr(ds_mod.config, "HOST_CONFIG_PATH", str(cfg))
        monkeypatch.setattr(ds_mod.audit_service.config, "CONTROL_AUDIT_LOG", str(log))
        svc, sm = self._svc()
        try:
            await svc._watch_host_config()  # baseline
            self._write_config(cfg, {"xvb": {"enabled": False}})
            # A commit landed AFTER the baseline check — it explains the change.
            log.write_text(
                json.dumps(
                    {
                        "ts": _iso_now(),
                        "id": "11111111-1111-4111-8111-111111111111",
                        "actor": "admin",
                        "action": "commit",
                        "status": "applied",
                        "keys": "XVB_ENABLED",
                    }
                )
                + "\n"
            )
            await svc._watch_host_config()
            assert sm.get_audit_events() == []
        finally:
            sm.close()

    async def test_commit_of_one_key_does_not_swallow_a_concurrent_host_edit(
        self, tmp_path, monkeypatch
    ):
        # #530 review MEDIUM: correlate BY KEY, not just by time. A fresh dashboard commit of key A
        # landing in the same window as a host-side hand-edit of key B must NOT suppress B — the
        # out-of-band change the feature exists to catch. Fails on the old time-only `explained =
        # any(...)` logic, which swallowed the whole diff on ANY fresh commit.
        cfg, log = tmp_path / "config.json", tmp_path / "control.log"
        # A: xvb.enabled (committable, maps to XVB_ENABLED). B: dashboard.tari_required (maps to
        # TARI_REQUIRED) — hand-edited on the host, NOT named by the commit below.
        self._write_config(cfg, {"xvb": {"enabled": True}, "dashboard": {"tari_required": True}})
        monkeypatch.setattr(ds_mod.config, "DASHBOARD_CONTROL_ENABLED", True)
        monkeypatch.setattr(ds_mod.config, "HOST_CONFIG_PATH", str(cfg))
        monkeypatch.setattr(ds_mod.audit_service.config, "CONTROL_AUDIT_LOG", str(log))
        svc, sm = self._svc()
        try:
            await svc._watch_host_config()  # baseline
            # Both keys change; only A was actually committed through the dashboard.
            self._write_config(
                cfg, {"xvb": {"enabled": False}, "dashboard": {"tari_required": False}}
            )
            log.write_text(
                json.dumps(
                    {
                        "ts": _iso_now(),
                        "id": "11111111-1111-4111-8111-111111111111",
                        "actor": "admin",
                        "action": "commit",
                        "status": "applied",
                        "keys": "XVB_ENABLED",
                    }
                )
                + "\n"
            )
            await svc._watch_host_config()
            events = sm.get_audit_events()
            # B is recorded out-of-band; A (explained by the commit) is NOT double-recorded.
            assert len(events) == 1
            assert events[0]["source"] == "host-edit"
            assert events[0]["keys"] == "dashboard.tari_required"
        finally:
            sm.close()

    async def test_energy_commit_explains_an_energy_subkey_by_prefix(self, tmp_path, monkeypatch):
        # #530: dashboard.energy.* is config.json-only and audits under the synthetic
        # DASHBOARD_ENERGY name, which env_key_config_paths maps to the whole `dashboard.energy`
        # block by prefix — so a committed energy sub-key change stays quiet even though its dotted
        # diff path (dashboard.energy.cost_per_kwh) isn't the literal committed name.
        cfg, log = tmp_path / "config.json", tmp_path / "control.log"
        self._write_config(cfg, {"dashboard": {"energy": {"cost_per_kwh": 0.10}}})
        monkeypatch.setattr(ds_mod.config, "DASHBOARD_CONTROL_ENABLED", True)
        monkeypatch.setattr(ds_mod.config, "HOST_CONFIG_PATH", str(cfg))
        monkeypatch.setattr(ds_mod.audit_service.config, "CONTROL_AUDIT_LOG", str(log))
        svc, sm = self._svc()
        try:
            await svc._watch_host_config()  # baseline
            self._write_config(cfg, {"dashboard": {"energy": {"cost_per_kwh": 0.20}}})
            log.write_text(
                json.dumps(
                    {
                        "ts": _iso_now(),
                        "id": "11111111-1111-4111-8111-111111111111",
                        "actor": "admin",
                        "action": "commit",
                        "status": "applied",
                        "keys": "DASHBOARD_ENERGY",
                    }
                )
                + "\n"
            )
            await svc._watch_host_config()
            assert sm.get_audit_events() == []
        finally:
            sm.close()

    async def test_stale_commit_before_the_last_check_does_not_explain(self, tmp_path, monkeypatch):
        cfg, log = tmp_path / "config.json", tmp_path / "control.log"
        self._write_config(cfg, {"xvb": {"enabled": True}})
        monkeypatch.setattr(ds_mod.config, "DASHBOARD_CONTROL_ENABLED", True)
        monkeypatch.setattr(ds_mod.config, "HOST_CONFIG_PATH", str(cfg))
        monkeypatch.setattr(ds_mod.audit_service.config, "CONTROL_AUDIT_LOG", str(log))
        svc, sm = self._svc()
        try:
            # An old commit, already accounted for before this watcher ever ran, then a NEW
            # out-of-band change — the stale commit must not explain it away.
            log.write_text(
                json.dumps(
                    {
                        "ts": "2020-01-01T00:00:00Z",
                        "id": "11111111-1111-4111-8111-111111111111",
                        "actor": "admin",
                        "action": "commit",
                        "status": "applied",
                        "keys": "XVB_ENABLED",
                    }
                )
                + "\n"
            )
            await svc._watch_host_config()  # baseline
            self._write_config(cfg, {"xvb": {"enabled": False}})
            await svc._watch_host_config()
            events = sm.get_audit_events()
            assert len(events) == 1
            assert events[0]["source"] == "host-edit"
        finally:
            sm.close()

    async def test_missing_mount_is_a_quiet_noop(self, monkeypatch):
        monkeypatch.setattr(ds_mod.config, "DASHBOARD_CONTROL_ENABLED", True)
        monkeypatch.setattr(ds_mod.config, "HOST_CONFIG_PATH", "/nonexistent/config.json")
        svc, sm = self._svc()
        try:
            await svc._watch_host_config()
            assert sm.get_audit_events() == []
        finally:
            sm.close()

    async def test_a_raw_secret_value_never_reaches_the_audit_row(self, tmp_path, monkeypatch):
        # Defense-in-depth (#530 review MEDIUM): even if the host masking regressed and left a RAW
        # secret in the mounted copy, the re-mask keeps its value out of the persisted snapshot and
        # out of any audit row. Change a non-secret key alongside the raw secret; the row names the
        # non-secret key only, and the secret value appears nowhere.
        cfg, log = tmp_path / "config.json", tmp_path / "control.log"
        self._write_config(
            cfg, {"dashboard": {"auth": {"password": "s3cr3t-raw"}}, "xvb": {"enabled": True}}
        )
        monkeypatch.setattr(ds_mod.config, "DASHBOARD_CONTROL_ENABLED", True)
        monkeypatch.setattr(ds_mod.config, "HOST_CONFIG_PATH", str(cfg))
        monkeypatch.setattr(ds_mod.audit_service.config, "CONTROL_AUDIT_LOG", str(log))
        svc, sm = self._svc()
        try:
            await svc._watch_host_config()  # baseline (secret already masked in the snapshot)
            assert svc._last_host_config["dashboard"]["auth"]["password"] == {"__secret__": True}
            self._write_config(
                cfg,
                {"dashboard": {"auth": {"password": "s3cr3t-changed"}}, "xvb": {"enabled": False}},
            )
            await svc._watch_host_config()
            events = sm.get_audit_events()
            assert len(events) == 1
            assert events[0]["keys"] == "xvb.enabled"  # the secret masks to a sentinel both sides
            blob = json.dumps(events) + json.dumps(svc._last_host_config)
            assert "s3cr3t-raw" not in blob and "s3cr3t-changed" not in blob
        finally:
            sm.close()

    async def test_explained_window_is_at_most_one_second(self, tmp_path, monkeypatch):
        # Boundary (#530 review LOW): the "explained by a fresh commit" check floors `since` to
        # `_last_host_check - 1` to absorb the audit log's whole-second ts truncation. That grace
        # is exactly 1s wide — a commit 1s before the last check still explains (truncation), one
        # 2s before does not. Pinned here so the honest ceiling can't silently widen.
        cfg, log = tmp_path / "config.json", tmp_path / "control.log"
        monkeypatch.setattr(ds_mod.config, "DASHBOARD_CONTROL_ENABLED", True)
        monkeypatch.setattr(ds_mod.config, "HOST_CONFIG_PATH", str(cfg))
        monkeypatch.setattr(ds_mod.audit_service.config, "CONTROL_AUDIT_LOG", str(log))
        check_epoch = _parse_audit_ts("2026-07-20T12:00:05Z")

        async def _run_with_commit_ts(commit_ts):
            svc, sm = self._svc()
            svc._last_host_config = {"xvb": {"enabled": True}}
            svc._last_host_check = check_epoch
            self._write_config(cfg, {"xvb": {"enabled": False}})
            log.write_text(
                json.dumps(
                    {
                        "ts": commit_ts,
                        "id": "11111111-1111-4111-8111-111111111111",
                        "actor": "admin",
                        "action": "commit",
                        "status": "applied",
                        "keys": "XVB_ENABLED",
                    }
                )
                + "\n"
            )
            try:
                await svc._watch_host_config()
                return len(sm.get_audit_events())
            finally:
                sm.close()

        # 1s before the last check: still explains (truncation grace) -> no host-edit row.
        assert await _run_with_commit_ts("2026-07-20T12:00:04Z") == 0
        # 2s before: outside the grace, correctly NOT explained -> host-edit recorded.
        assert await _run_with_commit_ts("2026-07-20T12:00:03Z") == 1
