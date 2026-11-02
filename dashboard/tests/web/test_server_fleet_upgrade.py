# ruff: noqa: F403, F405
import os
import time

from mining_dashboard.service.workers import fleet_upgrade, worker_refresh
from mining_dashboard.web import fleet_upgrade_views
from tests.web._server_support import *  # noqa: F403


def _rig(name, version="1.14.0"):
    return {
        "name": name,
        "status": "online",
        "adopted": True,
        "api_ok": True,
        "rigforge": _fresh_version(version),
    }


@pytest.fixture
async def fleet_client(aiohttp_client, control_spool, monkeypatch):
    monkeypatch.setattr(worker_refresh, "REFRESH_ATTEMPTS", 0)
    data = {
        "workers": [_rig("rig-b"), _rig("rig-a"), _rig("current", "1.15.0")],
        "rigforge_release": {"tag": "v1.15.0", "url": "https://example.invalid/r"},
    }
    sent = []

    async def notify(text):
        sent.append(text)

    sm = StateManager(db_path=":memory:")
    cli = await aiohttp_client(create_app(sm, data, notify))
    cli.sm, cli.sent, cli.spool = sm, sent, control_spool
    yield cli
    sm.close()


def _write_result(spool, rid, body):
    (spool / "results" / f"{rid}.json").write_text(json.dumps(body))


class TestFleetUpgradeState:
    async def test_reports_the_plan_and_no_run_yet(self, fleet_client):
        body = await (await fleet_client.get("/api/control/worker-upgrade-all")).json()
        assert body["version"] == "v1.15.0"
        assert [r["name"] for r in body["eligible"]] == ["rig-a", "rig-b"]
        assert body["run"] is None

    async def test_reports_the_newest_run_so_progress_survives_a_reload(self, fleet_client):
        rid = str(uuid.uuid4())
        _write_result(
            fleet_client.spool,
            rid,
            {"action": "worker-upgrade-all", "status": "running", "rigs": [{"name": "rig-a"}]},
        )
        _write_result(fleet_client.spool, str(uuid.uuid4()), {"action": "tor-newnym"})
        body = await (await fleet_client.get("/api/control/worker-upgrade-all")).json()
        assert body["run"]["id"] == rid and body["run"]["status"] == "running"

    async def test_a_host_rejection_is_the_newest_run_and_replaces_the_old_one(self, fleet_client):
        done = str(uuid.uuid4())
        _write_result(
            fleet_client.spool, done, {"action": "worker-upgrade-all", "status": "completed"}
        )
        os.utime(fleet_client.spool / "results" / f"{done}.json", (1, 1))
        rejected = str(uuid.uuid4())
        _write_result(
            fleet_client.spool,
            rejected,
            {"action": "worker-upgrade-all", "status": "rejected", "error": "cooldown"},
        )
        body = await (await fleet_client.get("/api/control/worker-upgrade-all")).json()
        assert body["run"]["id"] == rejected
        assert body["run"]["status"] == "rejected" and body["run"]["error"] == "cooldown"


class TestFleetUpgradeStart:
    async def _post(self, cli, body=None, headers=CONTROL_HEADERS):
        return await cli.post(
            "/api/control/worker-upgrade-all",
            json=body if body is not None else {"version": "v1.15.0"},
            headers=headers,
        )

    async def test_requires_control_header(self, fleet_client):
        assert (await self._post(fleet_client, headers={})).status == 403

    async def test_spools_host_derived_rig_names_only(self, fleet_client, monkeypatch):
        rid = str(uuid.uuid4())
        monkeypatch.setattr(fleet_upgrade.uuid, "uuid4", lambda: uuid.UUID(rid))
        resp = await self._post(fleet_client, {"version": "v1.15.0", "workers": ["evil"]})
        assert resp.status == 202
        req = json.loads((fleet_client.spool / "requests" / f"{rid}.json").read_text())
        assert req["action"] == "worker-upgrade-all"
        assert req["workers"] == ["rig-a", "rig-b"] and req["version"] == "v1.15.0"
        assert set(req) == {"id", "action", "actor", "workers", "version"}
        for t in list(fleet_client.app["_bg_tasks"]):
            t.cancel()

    async def test_a_version_the_dashboard_no_longer_shows_is_a_conflict(self, fleet_client):
        assert (await self._post(fleet_client, {"version": "v1.14.0"})).status == 409

    async def test_nothing_behind_is_a_conflict(self, fleet_client):
        for w in fleet_client.app["latest_data"]["workers"]:
            w["rigforge"] = _fresh_version("1.15.0")
        assert (await self._post(fleet_client)).status == 409

    async def test_a_run_in_progress_blocks_a_second_one_unless_it_is_stale(self, fleet_client):
        rid = str(uuid.uuid4())
        _write_result(
            fleet_client.spool,
            rid,
            {"action": "worker-upgrade-all", "status": "running", "ts": int(time.time())},
        )
        assert (await self._post(fleet_client)).status == 409
        _write_result(
            fleet_client.spool,
            rid,
            {"action": "worker-upgrade-all", "status": "running", "ts": int(time.time()) - 99999},
        )
        assert (await self._post(fleet_client)).status == 202
        for t in list(fleet_client.app["_bg_tasks"]):
            t.cancel()

    async def test_settled_run_is_recorded_per_rig_and_summarised_once(
        self, fleet_client, monkeypatch
    ):
        rid = str(uuid.uuid4())
        monkeypatch.setattr(fleet_upgrade.uuid, "uuid4", lambda: uuid.UUID(rid))
        _write_result(
            fleet_client.spool,
            rid,
            {
                "action": "worker-upgrade-all",
                "status": "completed",
                "version": "v1.15.0",
                "rigs": [
                    {"name": "rig-a", "status": "applied", "change_id": "c1", "reason": None},
                    {"name": "rig-b", "status": "failed", "change_id": "c2", "reason": "boom"},
                    {"name": "rig-z", "status": "not_started", "reason": "over the limit"},
                ],
            },
        )
        assert (await self._post(fleet_client)).status == 202
        await asyncio.gather(*fleet_client.app["_bg_tasks"])
        a = fleet_client.sm.get_worker_config_history("rig-a")
        b = fleet_client.sm.get_worker_config_history("rig-b")
        assert [(h["status"], h["type"]) for h in a] == [("applied", "upgrade")]
        assert [(h["status"], h["change_id"]) for h in b] == [("failed", "c2")]
        assert fleet_client.sm.get_worker_config_history("rig-z") == []
        assert len(fleet_client.sent) == 1 and "rig-b: failed (boom)" in fleet_client.sent[0]

    async def test_an_unanswered_or_broken_wait_records_and_sends_nothing(
        self, fleet_client, monkeypatch
    ):
        monkeypatch.setattr(fleet_upgrade_views, "RUN_WAIT_S", 0.05)
        assert (await self._post(fleet_client)).status == 202
        await asyncio.gather(*fleet_client.app["_bg_tasks"])

        async def boom(*a, **k):
            raise OSError("results gone")

        monkeypatch.setattr(control_service, "wait_result", boom)
        assert (await self._post(fleet_client)).status == 202
        await asyncio.gather(*fleet_client.app["_bg_tasks"])
        assert fleet_client.sent == []
        assert fleet_client.sm.get_worker_config_history("rig-a") == []

    async def test_a_second_click_before_the_host_answers_is_a_conflict(self, fleet_client):
        assert (await self._post(fleet_client)).status == 202
        assert (await self._post(fleet_client)).status == 409
        for t in list(fleet_client.app["_bg_tasks"]):
            t.cancel()

    async def test_a_rejected_run_sends_no_summary(self, fleet_client, monkeypatch):
        rid = str(uuid.uuid4())
        monkeypatch.setattr(control_service.uuid, "uuid4", lambda: uuid.UUID(rid))
        _write_result(fleet_client.spool, rid, {"status": "rejected", "error": "cooldown"})
        assert (await self._post(fleet_client)).status == 202
        await asyncio.gather(*fleet_client.app["_bg_tasks"])
        assert fleet_client.sent == []

    async def test_one_rig_failing_to_record_does_not_stop_the_rest(
        self, fleet_client, monkeypatch
    ):
        rid = str(uuid.uuid4())
        monkeypatch.setattr(control_service.uuid, "uuid4", lambda: uuid.UUID(rid))
        _write_result(
            fleet_client.spool,
            rid,
            {
                "action": "worker-upgrade-all",
                "status": "completed",
                "version": "v1.15.0",
                "rigs": [
                    {"name": "rig-a", "status": "applied"},
                    {"name": "rig-b", "status": "failed"},
                ],
            },
        )
        real = fleet_client.sm.add_worker_config_version

        def flaky(worker, *a, **k):
            if worker == "rig-a":
                raise RuntimeError("db")
            return real(worker, *a, **k)

        monkeypatch.setattr(fleet_client.sm, "add_worker_config_version", flaky)
        assert (await self._post(fleet_client)).status == 202
        await asyncio.gather(*fleet_client.app["_bg_tasks"])
        assert len(fleet_client.sm.get_worker_config_history("rig-b")) == 1
        assert len(fleet_client.sent) == 1

    async def test_a_non_object_body_is_a_400(self, fleet_client):
        resp = await fleet_client.post(
            "/api/control/worker-upgrade-all", json=[1], headers=CONTROL_HEADERS
        )
        assert resp.status == 400

    async def test_a_failed_submit_is_a_500_without_detail(self, fleet_client, monkeypatch):
        def boom(*a, **k):
            raise OSError("spool dir gone")

        monkeypatch.setattr(fleet_upgrade, "submit_worker_upgrade_all", boom)
        resp = await self._post(fleet_client)
        assert resp.status == 500 and "spool" not in await resp.text()

    async def test_a_non_json_body_is_a_400(self, fleet_client):
        resp = await fleet_client.post(
            "/api/control/worker-upgrade-all", data=b"nope", headers=CONTROL_HEADERS
        )
        assert resp.status == 400
