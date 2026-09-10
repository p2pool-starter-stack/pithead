# ruff: noqa: F403, F405
from tests.web._server_support import *  # noqa: F403


class TestWorkerApplyEdgeCases:
    async def test_apply_bad_body_and_missing_worker(self, worker_client):
        # Non-JSON body → 400.
        resp = await worker_client.post(
            "/api/control/worker-apply", data="not json", headers=CONTROL_HEADERS
        )
        assert resp.status == 400
        # Missing / empty worker name → 400.
        resp = await worker_client.post(
            "/api/control/worker-apply", json={"changes": {"DONATION": 1}}, headers=CONTROL_HEADERS
        )
        assert resp.status == 400

    async def test_apply_pending_when_runner_silent(
        self, worker_client, control_spool, monkeypatch
    ):
        # No result file is written, so wait_result times out → 202 pending, nothing recorded.
        rid = str(uuid.uuid4())
        monkeypatch.setattr(control_service.uuid, "uuid4", lambda: uuid.UUID(rid))
        monkeypatch.setattr(control_service.config, "CONTROL_WAIT_S", 0.05)
        resp = await worker_client.post(
            "/api/control/worker-apply",
            json={"worker": "rig1", "changes": {"DONATION": 1}},
            headers={**CONTROL_HEADERS},
        )
        assert resp.status == 202
        assert (await resp.json())["status"] == "pending"
        assert worker_client.sm.get_worker_config_history("rig1") == []  # no terminal outcome yet
