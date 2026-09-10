# ruff: noqa: F403, F405
from tests.web._server_support import *  # noqa: F403


class TestWorkerUpgradeRecordsHistory:
    """#1014: a one-click rig upgrade is 202-then-poll (a rebuild can run minutes), so the
    terminal outcome is recorded by a background task, not inline like worker-apply's. These pin
    that task down directly (`await asyncio.gather(*app["_bg_tasks"])`) rather than sleeping."""

    async def _upgrade(self, worker_client, control_spool, monkeypatch, result):
        rid = str(uuid.uuid4())
        monkeypatch.setattr(control_service.uuid, "uuid4", lambda: uuid.UUID(rid))
        (control_spool / "results" / f"{rid}.json").write_text(json.dumps(result))
        resp = await worker_client.post(
            "/api/control/worker-upgrade",
            json={"worker": "rig1", "version": "v1.11.2"},
            headers=CONTROL_HEADERS,
        )
        assert resp.status == 202
        await asyncio.gather(*worker_client.app["_bg_tasks"])
        return rid

    async def test_applied_upgrade_recorded_as_its_own_type(
        self, worker_client, control_spool, monkeypatch
    ):
        result = {
            "status": "applied",
            "change_id": "deadbeef",
            "worker": "rig1",
            "version": "v1.11.2",
            "reason": None,
        }
        await self._upgrade(worker_client, control_spool, monkeypatch, result)
        history = worker_client.sm.get_worker_config_history("rig1")
        assert len(history) == 1
        assert history[0]["status"] == "applied"
        assert history[0]["type"] == "upgrade"
        assert history[0]["changes"] == {"version": "v1.11.2"}
        assert history[0]["change_id"] == "deadbeef"
        # An applied upgrade must never leak into the config-editor prefill (#1014's own guard).
        assert worker_client.sm.get_last_applied_worker_config("rig1") == {}

    async def test_noop_and_throttled_terminals_from_a_real_dial_are_recorded(
        self, worker_client, control_spool, monkeypatch
    ):
        # Distinct from the synchronous short-circuit noop above: this is the RIG's own /status
        # terminal for a dial that actually happened (rigforge#320's first-class noop/throttled).
        for status in ("noop", "throttled"):
            result = {
                "status": status,
                "change_id": f"cid-{status}",
                "worker": "rig1",
                "version": "v1.11.2",
                "reason": "already current" if status == "noop" else "throttled: retry later",
            }
            await self._upgrade(worker_client, control_spool, monkeypatch, result)
        statuses = {h["status"] for h in worker_client.sm.get_worker_config_history("rig1")}
        assert statuses == {"noop", "throttled"}

    async def test_pre_dial_rejection_recorded_with_the_requesters_worker_name(
        self, worker_client, control_spool, monkeypatch
    ):
        # The host runner's pre-dial _wu_reject writes NO 'worker' key at all — the row must still
        # land under the right worker, from the request itself, not from the result body.
        result = {"status": "rejected", "error": "worker has no configured host", "ts": 1.0}
        await self._upgrade(worker_client, control_spool, monkeypatch, result)
        history = worker_client.sm.get_worker_config_history("rig1")
        assert len(history) == 1
        assert history[0]["status"] == "rejected"
        assert history[0]["type"] == "upgrade"
        assert history[0]["reason"] == "worker has no configured host"
        assert history[0]["changes"] == {"version": "v1.11.2"}  # the operator-proposed target

    async def test_runner_never_answering_records_nothing(
        self, worker_client, control_spool, monkeypatch
    ):
        monkeypatch.setattr(control_service.config, "CONTROL_WORKER_UPGRADE_WAIT_S", 0.05)
        rid = str(uuid.uuid4())
        monkeypatch.setattr(control_service.uuid, "uuid4", lambda: uuid.UUID(rid))
        resp = await worker_client.post(
            "/api/control/worker-upgrade",
            json={"worker": "rig1", "version": "v1.11.2"},
            headers=CONTROL_HEADERS,
        )
        assert resp.status == 202
        await asyncio.gather(*worker_client.app["_bg_tasks"])
        assert worker_client.sm.get_worker_config_history("rig1") == []

    async def test_wait_result_error_is_swallowed_not_raised(
        self, worker_client, control_spool, monkeypatch
    ):
        # A crash while polling for the terminal result (e.g. a spool read error) must not blow up
        # the background task or take the app down with it — logged and dropped, like every other
        # exception boundary in this module.
        async def boom(*a, **k):
            raise OSError("spool read failed")

        monkeypatch.setattr(control_service, "wait_result", boom)
        resp = await worker_client.post(
            "/api/control/worker-upgrade",
            json={"worker": "rig1", "version": "v1.11.2"},
            headers=CONTROL_HEADERS,
        )
        assert resp.status == 202
        await asyncio.gather(*worker_client.app["_bg_tasks"])  # must not raise
        assert worker_client.sm.get_worker_config_history("rig1") == []
