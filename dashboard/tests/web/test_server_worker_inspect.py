# ruff: noqa: F403, F405
from tests.web._server_support import *  # noqa: F403


class TestWorkerInspect:
    async def test_worker_detail_reports_editable_and_telemetry(self, worker_client):
        resp = await worker_client.get("/api/worker?name=rig1")
        assert resp.status == 200
        body = await resp.json()
        assert body["found"] is True
        assert body["editable"] is True  # has an operator-set host
        assert body["status"] == "online"
        assert "DONATION" in body["writable_keys"]
        assert body["history"] == []

    async def test_worker_detail_requires_name(self, worker_client):
        assert (await worker_client.get("/api/worker")).status == 400

    async def test_worker_apply_requires_control_header(self, worker_client):
        resp = await worker_client.post(
            "/api/control/worker-apply", json={"worker": "rig1", "changes": {"DONATION": 2}}
        )
        assert resp.status == 403  # CSRF guard

    async def test_worker_apply_rejects_non_writable_keys(self, worker_client):
        resp = await worker_client.post(
            "/api/control/worker-apply",
            json={"worker": "rig1", "changes": {"ACCESS_TOKEN": "x"}},
            headers=CONTROL_HEADERS,
        )
        assert resp.status == 400  # not in the writable allowlist

    async def test_worker_apply_spools_tokenless_intent_and_records_history(
        self, worker_client, control_spool, monkeypatch
    ):
        # Pin the id and pre-write the host runner's terminal result so wait_result returns at once.
        rid = str(uuid.uuid4())
        monkeypatch.setattr(control_service.uuid, "uuid4", lambda: uuid.UUID(rid))
        result = {
            "status": "applied",
            "change_id": "deadbeefcafef00d",
            "worker": "rig1",
            "reason": None,
        }
        (control_spool / "results" / f"{rid}.json").write_text(json.dumps(result))

        # A leftover pool-credential sentinel (#1548) is scrubbed before spool/rig/record alike.
        sent = {"DONATION": 3, "pools": [{"url": "rig:3333", "pass": {"__secret__": True}}]}
        scrubbed = {"DONATION": 3, "pools": [{"url": "rig:3333"}]}
        resp = await worker_client.post(
            "/api/control/worker-apply",
            json={"worker": "rig1", "changes": sent},
            headers=CONTROL_HEADERS,
        )
        assert resp.status == 200
        body = await resp.json()
        assert body["status"] == "applied" and body["change_id"] == "deadbeefcafef00d"
        # The spooled intent carries ONLY the worker name + changes — never a host, port, or token.
        req = json.loads((control_spool / "requests" / f"{rid}.json").read_text())
        assert req["action"] == "worker-apply"
        assert req["worker"] == "rig1" and req["changes"] == scrubbed
        assert "host" not in req and "port" not in req and "token" not in req
        # The outcome is recorded in the per-worker config history, scrubbed the same way.
        history = worker_client.sm.get_worker_config_history("rig1")
        assert len(history) == 1
        assert history[0]["status"] == "applied"
        assert history[0]["changes"] == scrubbed
        assert worker_client.sm.get_last_applied_worker_config("rig1") == scrubbed

    async def test_worker_routes_absent_when_control_disabled(self, client):
        assert (await client.get("/api/worker?name=rig1")).status == 404
        assert (
            await client.post("/api/control/worker-apply", json={}, headers=CONTROL_HEADERS)
        ).status == 404
