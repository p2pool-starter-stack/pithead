# ruff: noqa: F403, F405
from tests.web._server_support import *  # noqa: F403


class TestWorkerUpgrade:
    """The one-click rig upgrade route (#597): spool-only, name + confirmed version, no waiting."""

    async def test_requires_control_header(self, worker_client):
        resp = await worker_client.post(
            "/api/control/worker-upgrade", json={"worker": "rig1", "version": "v1.11.2"}
        )
        assert resp.status == 403  # CSRF guard

    async def test_malformed_worker_or_version_rejected(self, worker_client):
        for body in (
            {"version": "v1.11.2"},  # missing worker
            {"worker": "", "version": "v1.11.2"},  # empty worker
            {"worker": "rig1"},  # missing version
            {"worker": "rig1", "version": "1.11.2"},  # bare — the intent carries the tag form
            {"worker": "rig1", "version": "v1.11.2;rm"},  # junk after the tag
        ):
            resp = await worker_client.post(
                "/api/control/worker-upgrade", json=body, headers=CONTROL_HEADERS
            )
            assert resp.status == 400, body

    async def test_spools_name_and_version_only_and_returns_202(
        self, worker_client, control_spool, monkeypatch
    ):
        rid = str(uuid.uuid4())
        monkeypatch.setattr(control_service.uuid, "uuid4", lambda: uuid.UUID(rid))
        resp = await worker_client.post(
            "/api/control/worker-upgrade",
            json={"worker": "rig1", "version": "v1.11.2"},
            headers=CONTROL_HEADERS,
        )
        # Always 202 — a rig build can run minutes, so the client polls /api/control/result.
        assert resp.status == 202
        body = await resp.json()
        assert body["status"] == "pending" and body["id"] == rid
        # The intent carries ONLY the worker name + proposed version — never host/port/token.
        req = json.loads((control_spool / "requests" / f"{rid}.json").read_text())
        assert req["action"] == "worker-upgrade"
        assert req["worker"] == "rig1" and req["version"] == "v1.11.2"
        assert "host" not in req and "port" not in req and "token" not in req
        assert "changes" not in req

    async def test_non_json_body_is_a_400(self, worker_client):
        resp = await worker_client.post(
            "/api/control/worker-upgrade", data=b"not json", headers=CONTROL_HEADERS
        )
        assert resp.status == 400
        assert "must be JSON" in await resp.text()

    async def test_submit_failure_is_a_500_without_detail(self, worker_client, monkeypatch):
        def boom(*a, **k):
            raise OSError("spool dir gone")

        monkeypatch.setattr(control_service, "submit_worker_upgrade", boom)
        resp = await worker_client.post(
            "/api/control/worker-upgrade",
            json={"worker": "rig1", "version": "v1.11.2"},
            headers=CONTROL_HEADERS,
        )
        assert resp.status == 500
        # The body carries a generic message, never the exception text.
        assert "spool dir gone" not in await resp.text()

    async def test_noop_when_rig_already_reports_the_version(self, worker_client, control_spool):
        # Bare "1.11.0" and tag v1.11.0 must compare equal without a host dial.
        resp = await worker_client.post(
            "/api/control/worker-upgrade",
            json={"worker": "rig1", "version": "v1.11.0"},
            headers=CONTROL_HEADERS,
        )
        assert resp.status == 200
        assert (await resp.json())["status"] == "noop"
        assert list((control_spool / "requests").glob("*.json")) == []
        assert worker_client.sm.get_worker_config_history("rig1") == []

    async def test_route_absent_when_control_disabled(self, client):
        resp = await client.post(
            "/api/control/worker-upgrade",
            json={"worker": "rig1", "version": "v1.11.2"},
            headers=CONTROL_HEADERS,
        )
        assert resp.status == 404
