# ruff: noqa: F403, F405
from tests.web._server_support import *  # noqa: F403


class TestSecurityLogRoutes:
    """/api/access (always on) and /api/audit (with the control channel) — #349. Both are GET-only
    reads over host-written, read-only-mounted files; every served field is sanitized because log
    content is attacker-influenceable (the access log echoes attacker-chosen URIs/usernames)."""

    async def test_access_route_reports_unavailable_without_log(self, client, monkeypatch):
        monkeypatch.setattr(audit_service.config, "ACCESS_LOG_PATH", "/nonexistent/access.log")
        resp = await client.get("/api/access")
        assert resp.status == 200
        body = await resp.json()
        assert body["available"] is False
        assert body["entries"] == []

    async def test_access_route_serves_sanitized_entries(self, client, tmp_path, monkeypatch):
        log = tmp_path / "access.log"
        log.write_text(
            json.dumps(
                {
                    "ts": 100.0,
                    "status": 401,
                    "user_id": "<script>alert(1)</script>",
                    "request": {"method": "GET", "uri": "/<svg onload=alert(1)>"},
                }
            )
            + "\n"
        )
        monkeypatch.setattr(audit_service.config, "ACCESS_LOG_PATH", str(log))
        resp = await client.get("/api/access")
        assert resp.status == 200
        text = json.dumps(await resp.json())
        # A hostile log line must arrive inert — no markup survives to the browser.
        assert "<" not in text and ">" not in text
        assert (await client.get("/api/access")).status == 200

    async def test_audit_route_serves_sanitized_entries(
        self, control_client, tmp_path, monkeypatch
    ):
        log = tmp_path / "control.log"
        log.write_text(
            json.dumps(
                {
                    "ts": "2026-07-10T12:00:00Z",
                    "id": "11111111-1111-4111-8111-111111111111",
                    "actor": "<img src=x onerror=alert(1)>",
                    "action": "commit",
                    "status": "applied",
                    "keys": "XVB_ENABLED",
                }
            )
            + "\n"
        )
        monkeypatch.setattr(audit_service.config, "CONTROL_AUDIT_LOG", str(log))
        resp = await control_client.get("/api/audit")
        assert resp.status == 200
        body = await resp.json()
        assert body["entries"][0]["keys"] == "XVB_ENABLED"
        assert "<" not in json.dumps(body) and ">" not in json.dumps(body)

    async def test_access_route_navigation_params_filter_entries(
        self, client, tmp_path, monkeypatch
    ):
        # #823: from/to (epoch seconds, half-open) and q narrow the served entries; the failure
        # counters keep describing the whole tail; malformed bounds read as absent, never a 500.
        log = tmp_path / "access.log"
        rows = [
            {
                "ts": 100.0,
                "status": 200,
                "user_id": "admin",
                "request": {"method": "GET", "uri": "/api/state"},
            },
            {
                "ts": 200.0,
                "status": 401,
                "user_id": "guess",
                "request": {"method": "GET", "uri": "/login"},
            },
        ]
        log.write_text("".join(json.dumps(r) + "\n" for r in rows))
        monkeypatch.setattr(audit_service.config, "ACCESS_LOG_PATH", str(log))
        body = await (await client.get("/api/access?from=150")).json()
        assert [e["ts"] for e in body["entries"]] == [200.0]
        body = await (await client.get("/api/access?q=api/state")).json()
        assert [e["ts"] for e in body["entries"]] == [100.0]
        # to is exclusive; and the 401 counter is window-independent (whole-tail semantics).
        body = await (await client.get("/api/access?from=100&to=200")).json()
        assert [e["ts"] for e in body["entries"]] == [100.0]
        assert "failures_24h" in body
        # Malformed bounds degrade to unfiltered, HTTP 200 — including the float()-parseable
        # non-finite spellings, which would otherwise warp the comparisons (nan is never <).
        for bad in ("notanumber", "inf", "-inf", "nan", ""):
            resp = await client.get(f"/api/access?from={bad}&to={bad}&q=")
            assert resp.status == 200
            assert len((await resp.json())["entries"]) == 2

    async def test_audit_route_navigation_params_filter_entries(
        self, control_client, tmp_path, monkeypatch
    ):
        # #823 on the audit side: ISO timestamps land on the same epoch axis, and q searches
        # the sanitized fields.
        log = tmp_path / "control.log"
        rows = [
            {
                "ts": "2026-07-10T12:00:00Z",
                "id": "11111111-1111-4111-8111-111111111111",
                "actor": "admin",
                "action": "commit",
                "status": "applied",
                "keys": "XVB_ENABLED",
            },
            {
                "ts": "2026-07-20T12:00:00Z",
                "id": "22222222-2222-4222-8222-222222222222",
                "actor": "release-smoke",
                "action": "upgrade",
                "status": "upgraded",
                "keys": "",
            },
        ]
        log.write_text("".join(json.dumps(r) + "\n" for r in rows))
        monkeypatch.setattr(audit_service.config, "CONTROL_AUDIT_LOG", str(log))
        cutoff = audit_service._entry_epoch("2026-07-15T00:00:00Z")
        body = await (await control_client.get(f"/api/audit?from={cutoff}")).json()
        assert [e["actor"] for e in body["entries"]] == ["release-smoke"]
        body = await (await control_client.get("/api/audit?q=xvb_enabled")).json()
        assert [e["actor"] for e in body["entries"]] == ["admin"]

    async def test_audit_route_missing_log_is_empty(self, control_client, monkeypatch):
        monkeypatch.setattr(audit_service.config, "CONTROL_AUDIT_LOG", "/nonexistent/control.log")
        resp = await control_client.get("/api/audit")
        assert resp.status == 200
        assert (await resp.json())["entries"] == []

    async def test_access_route_failure_is_sanitized(self, client, monkeypatch):
        monkeypatch.setattr(
            audit_service, "access_summary", MagicMock(side_effect=RuntimeError("/host/secret"))
        )
        resp = await client.get("/api/access")
        assert resp.status == 500
        assert "secret" not in json.dumps(await resp.json())

    async def test_audit_route_failure_is_sanitized(self, control_client, monkeypatch):
        monkeypatch.setattr(
            audit_service, "recent_changes", MagicMock(side_effect=RuntimeError("/host/secret"))
        )
        resp = await control_client.get("/api/audit")
        assert resp.status == 500
        assert "secret" not in json.dumps(await resp.json())

    async def test_audit_route_merges_db_only_entries(self, control_client, monkeypatch):
        # #530: an out-of-band host-edit/rig-edit row lives only in audit_events, never in
        # control.log — it must still appear in the served feed.
        monkeypatch.setattr(audit_service.config, "CONTROL_AUDIT_LOG", "/nonexistent/control.log")
        state_mgr = control_client.app["state_manager"]
        state_mgr.add_audit_event(
            id="hostedit-1",
            ts="2026-07-20T12:00:00Z",
            source="host-edit",
            actor="",
            action="host-edit",
            status="detected",
            keys="xvb.enabled",
        )
        resp = await control_client.get("/api/audit")
        assert resp.status == 200
        entries = (await resp.json())["entries"]
        assert len(entries) == 1
        assert entries[0]["source"] == "host-edit"
        assert entries[0]["keys"] == "xvb.enabled"

    async def test_audit_route_shows_a_fresh_commit_before_it_is_mirrored(
        self, control_client, tmp_path, monkeypatch
    ):
        # A commit that just landed in control.log, before the next poll cycle mirrors it to the
        # DB, must still show up immediately — no regression from #530's DB merge.
        log = tmp_path / "control.log"
        log.write_text(
            json.dumps(
                {
                    "ts": "2026-07-20T12:00:00Z",
                    "id": "11111111-1111-4111-8111-111111111111",
                    "actor": "admin",
                    "action": "commit",
                    "status": "applied",
                    "keys": "XVB_ENABLED",
                }
            )
            + "\n"
        )
        monkeypatch.setattr(audit_service.config, "CONTROL_AUDIT_LOG", str(log))
        resp = await control_client.get("/api/audit")
        entries = (await resp.json())["entries"]
        assert len(entries) == 1
        assert entries[0]["keys"] == "XVB_ENABLED"

    async def test_audit_route_deduplicates_a_mirrored_row(
        self, control_client, tmp_path, monkeypatch
    ):
        # The same control.log row, present both live (log tail) and mirrored (DB) — one row out,
        # not two.
        log = tmp_path / "control.log"
        log.write_text(
            json.dumps(
                {
                    "ts": "2026-07-20T12:00:00Z",
                    "id": "22222222-2222-4222-8222-222222222222",
                    "actor": "admin",
                    "action": "commit",
                    "status": "applied",
                    "keys": "XVB_ENABLED",
                }
            )
            + "\n"
        )
        monkeypatch.setattr(audit_service.config, "CONTROL_AUDIT_LOG", str(log))
        state_mgr = control_client.app["state_manager"]
        state_mgr.add_audit_event(
            id="22222222-2222-4222-8222-222222222222",
            ts="2026-07-20T12:00:00Z",
            source="control",
            actor="admin",
            action="commit",
            status="applied",
            keys="XVB_ENABLED",
        )
        resp = await control_client.get("/api/audit")
        entries = (await resp.json())["entries"]
        assert len(entries) == 1

    async def test_audit_route_sorts_newest_first_across_sources(
        self, control_client, tmp_path, monkeypatch
    ):
        log = tmp_path / "control.log"
        log.write_text(
            json.dumps(
                {
                    "ts": "2026-07-01T00:00:00Z",
                    "id": "33333333-3333-4333-8333-333333333333",
                    "actor": "admin",
                    "action": "commit",
                    "status": "applied",
                    "keys": "XVB_ENABLED",
                }
            )
            + "\n"
        )
        monkeypatch.setattr(audit_service.config, "CONTROL_AUDIT_LOG", str(log))
        state_mgr = control_client.app["state_manager"]
        state_mgr.add_audit_event(
            id="hostedit-2",
            ts="2026-07-20T00:00:00Z",
            source="host-edit",
            actor="",
            action="host-edit",
            status="detected",
            keys="xvb.enabled",
        )
        resp = await control_client.get("/api/audit")
        entries = (await resp.json())["entries"]
        assert [e["id"] for e in entries] == ["hostedit-2", "33333333-3333-4333-8333-333333333333"]

    async def test_audit_route_shows_a_no_id_log_row_live(
        self, control_client, tmp_path, monkeypatch
    ):
        # A pre-auth "invalid"/"refused" control.log row (#33) has no id — never mirrored to the
        # DB, but still shown live from the log tail.
        log = tmp_path / "control.log"
        log.write_text(
            json.dumps(
                {
                    "ts": "2026-07-20T12:00:00Z",
                    "id": "",
                    "actor": "",
                    "action": "invalid",
                    "status": "refused-oversize",
                    "keys": "",
                }
            )
            + "\n"
        )
        monkeypatch.setattr(audit_service.config, "CONTROL_AUDIT_LOG", str(log))
        resp = await control_client.get("/api/audit")
        entries = (await resp.json())["entries"]
        assert len(entries) == 1
        assert entries[0]["status"] == "refused-oversize"
