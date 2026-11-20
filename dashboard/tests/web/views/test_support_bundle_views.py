import io
import json
import uuid
import zipfile

import pytest

from mining_dashboard.service import control_service
from mining_dashboard.service.health import diagnostics_service
from mining_dashboard.service.storage_service import StateManager
from mining_dashboard.web.server import create_app

CONTROL_HEADERS = {"X-Pithead-Control": "1"}


@pytest.fixture
def spool(tmp_path, monkeypatch):
    (tmp_path / "requests").mkdir()
    (tmp_path / "results").mkdir()
    monkeypatch.setattr(control_service.config, "DASHBOARD_CONTROL_ENABLED", True)
    monkeypatch.setattr(control_service.config, "CONTROL_REQUESTS_DIR", str(tmp_path / "requests"))
    monkeypatch.setattr(control_service.config, "CONTROL_RESULTS_DIR", str(tmp_path / "results"))
    return tmp_path


@pytest.fixture
async def bundle_client(aiohttp_client, spool):
    sm = StateManager(db_path=":memory:")
    cli = await aiohttp_client(create_app(sm, {}))
    yield cli
    sm.close()


def real_zip():
    buf = io.BytesIO()
    with zipfile.ZipFile(buf, "w") as z:
        z.writestr("bundle/manifest.json", json.dumps({"window": {"journal_short": False}}))
        z.writestr("bundle/journal/all.log", "line\n")
    return buf.getvalue()


def spooled(spool):
    files = list((spool / "requests").glob("*.json"))
    assert len(files) == 1, files
    return json.loads(files[0].read_text())


class TestSupportBundleWithTheControlSwitchOff:
    @pytest.fixture
    async def off_client(self, aiohttp_client, spool, monkeypatch):
        monkeypatch.setattr(control_service.config, "DASHBOARD_CONTROL_ENABLED", False)
        sm = StateManager(db_path=":memory:")
        cli = await aiohttp_client(create_app(sm, {}))
        yield cli
        sm.close()

    async def test_the_export_routes_exist_with_the_switch_off(self, off_client, spool):
        resp = await off_client.post(
            "/api/control/support-bundle", headers=CONTROL_HEADERS, json={"hours": 24}
        )
        assert resp.status == 202
        assert spooled(spool)["action"] == "support-bundle"
        rid = str(uuid.uuid4())
        resp = await off_client.get("/api/control/support-bundle-result", params={"id": rid})
        assert resp.status == 202
        resp = await off_client.get("/api/control/support-bundle-download", params={"id": rid})
        assert resp.status == 404

    async def test_the_export_still_needs_the_csrf_header_with_the_switch_off(self, off_client):
        assert (await off_client.post("/api/control/support-bundle", json={})).status == 403
        assert (await off_client.post("/api/control/support-bundle-range")).status == 403

    async def test_a_failing_range_submit_is_a_500(self, off_client, monkeypatch):
        def boom(*args, **kwargs):
            raise RuntimeError("the spool is on fire")

        monkeypatch.setattr(diagnostics_service, "submit_support_range", boom)
        resp = await off_client.post("/api/control/support-bundle-range", headers=CONTROL_HEADERS)
        assert resp.status == 500

    async def test_the_oldest_log_ask_spools_the_range_verb_with_the_switch_off(
        self, off_client, spool
    ):
        resp = await off_client.post("/api/control/support-bundle-range", headers=CONTROL_HEADERS)
        assert resp.status == 202
        assert spooled(spool)["action"] == "support-bundle-range"

    async def test_a_zip_downloads_with_the_switch_off(self, off_client, spool):
        rid = str(uuid.uuid4())
        (spool / "results" / f"{rid}.json").write_text(
            json.dumps({"status": "applied", "archive": "support-bundle-x.zip"})
        )
        (spool / "results" / f"{rid}.zip").write_bytes(real_zip())
        resp = await off_client.get("/api/control/support-bundle-download", params={"id": rid})
        assert resp.status == 200
        assert zipfile.ZipFile(io.BytesIO(await resp.read())).testzip() is None

    @pytest.mark.parametrize(
        ("method", "path"),
        [
            ("post", "/api/control/preview"),
            ("post", "/api/control/commit"),
            ("post", "/api/control/restart"),
            ("post", "/api/control/tor-reset"),
            ("post", "/api/control/diag-doctor"),
            ("get", "/api/config"),
            ("get", "/api/control/result?id=x"),
        ],
    )
    async def test_every_other_control_route_stays_404(self, off_client, method, path):
        assert (await getattr(off_client, method)(path, headers=CONTROL_HEADERS)).status == 404


class TestSupportBundleResultRoute:
    async def test_a_bad_id_is_a_400(self, bundle_client):
        resp = await bundle_client.get("/api/control/support-bundle-result", params={"id": "no"})
        assert resp.status == 400

    async def test_only_the_export_fields_are_returned(self, bundle_client, spool):
        rid = str(uuid.uuid4())
        (spool / "results" / f"{rid}.json").write_text(
            json.dumps(
                {
                    "status": "applied",
                    "archive": "support-bundle-x.zip",
                    "effective_since": "2026-11-15T10:00:00Z",
                    "journal_short": True,
                    "config": {"secret": "x"},
                    "passphrase": "x",
                }
            )
        )
        resp = await bundle_client.get("/api/control/support-bundle-result", params={"id": rid})
        assert resp.status == 200
        assert await resp.json() == {
            "status": "applied",
            "archive": "support-bundle-x.zip",
            "effective_since": "2026-11-15T10:00:00Z",
            "journal_short": True,
        }


class TestSupportBundleSubmit:
    async def test_requires_the_control_header(self, bundle_client):
        assert (await bundle_client.post("/api/control/support-bundle", json={})).status == 403

    async def test_no_body_spools_no_hours_key_so_the_host_states_its_default(
        self, bundle_client, spool
    ):
        resp = await bundle_client.post(
            "/api/control/support-bundle",
            headers={**CONTROL_HEADERS, "X-Auth-User": "admin"},
        )
        assert resp.status == 202
        body = await resp.json()
        assert spooled(spool) == {"id": body["id"], "action": "support-bundle", "actor": "admin"}

    async def test_the_stated_window_is_spooled_verbatim_because_the_host_clamps(
        self, bundle_client, spool
    ):
        resp = await bundle_client.post(
            "/api/control/support-bundle", headers=CONTROL_HEADERS, json={"hours": 9999}
        )
        assert resp.status == 202
        assert spooled(spool)["hours"] == 9999

    async def test_an_explicit_start_and_end_are_spooled_for_the_host_to_validate(
        self, bundle_client, spool
    ):
        resp = await bundle_client.post(
            "/api/control/support-bundle",
            headers=CONTROL_HEADERS,
            json={"since": "2026-11-15T10:00:00Z", "until": "2026-11-15T12:00:00Z"},
        )
        assert resp.status == 202
        intent = spooled(spool)
        assert intent["since"] == "2026-11-15T10:00:00Z"
        assert intent["until"] == "2026-11-15T12:00:00Z"
        assert "hours" not in intent

    @pytest.mark.parametrize("key", ["since", "until"])
    @pytest.mark.parametrize("value", [5, None, "", "x" * 41, ["2026-11-15T10:00:00Z"]])
    async def test_a_malformed_time_is_a_400_and_spools_nothing(
        self, bundle_client, spool, key, value
    ):
        resp = await bundle_client.post(
            "/api/control/support-bundle", headers=CONTROL_HEADERS, json={key: value}
        )
        assert resp.status == 400
        assert not list((spool / "requests").glob("*.json"))

    @pytest.mark.parametrize("hours", [True, 0, -1, "24", None, [24]])
    async def test_a_malformed_window_is_a_400_and_spools_nothing(
        self, bundle_client, spool, hours
    ):
        resp = await bundle_client.post(
            "/api/control/support-bundle", headers=CONTROL_HEADERS, json={"hours": hours}
        )
        assert resp.status == 400
        assert not list((spool / "requests").glob("*.json"))

    async def test_a_json_array_body_is_a_400_not_a_500(self, bundle_client):
        resp = await bundle_client.post(
            "/api/control/support-bundle",
            data="[1]",
            headers={**CONTROL_HEADERS, "Content-Type": "application/json"},
        )
        assert resp.status == 400

    async def test_a_malformed_json_body_is_a_400_and_spools_nothing(self, bundle_client, spool):
        resp = await bundle_client.post(
            "/api/control/support-bundle",
            data="{oops",
            headers={**CONTROL_HEADERS, "Content-Type": "application/json"},
        )
        assert resp.status == 400
        assert not list((spool / "requests").glob("*.json"))

    async def test_a_failing_submit_is_a_500_and_spools_nothing(
        self, bundle_client, monkeypatch, spool
    ):
        def boom(*args, **kwargs):
            raise RuntimeError("the spool is on fire")

        monkeypatch.setattr(diagnostics_service, "submit_support_bundle", boom)
        resp = await bundle_client.post(
            "/api/control/support-bundle", headers=CONTROL_HEADERS, json={"hours": 24}
        )
        assert resp.status == 500
        assert not list((spool / "requests").glob("*.json"))


class TestSupportBundleDownload:
    async def _result(self, spool, rid, payload):
        (spool / "results" / f"{rid}.json").write_text(json.dumps(payload))

    async def test_a_non_uuid_is_a_400(self, bundle_client):
        resp = await bundle_client.get(
            "/api/control/support-bundle-download", params={"id": "nope"}
        )
        assert resp.status == 400

    async def test_an_unknown_id_is_a_404(self, bundle_client):
        resp = await bundle_client.get(
            "/api/control/support-bundle-download", params={"id": str(uuid.uuid4())}
        )
        assert resp.status == 404

    @pytest.mark.parametrize("payload", [{"status": "running"}, {"status": "failed"}, {}])
    async def test_a_result_that_is_not_applied_is_a_404(self, bundle_client, spool, payload):
        rid = str(uuid.uuid4())
        await self._result(spool, rid, payload)
        resp = await bundle_client.get("/api/control/support-bundle-download", params={"id": rid})
        assert resp.status == 404

    async def test_applied_without_the_archive_on_disk_is_a_404(self, bundle_client, spool):
        rid = str(uuid.uuid4())
        await self._result(spool, rid, {"status": "applied", "archive": "support-bundle-x.zip"})
        resp = await bundle_client.get("/api/control/support-bundle-download", params={"id": rid})
        assert resp.status == 404

    async def test_applied_streams_the_spool_archive_under_its_named_filename(
        self, bundle_client, spool
    ):
        rid = str(uuid.uuid4())
        await self._result(spool, rid, {"status": "applied", "archive": "support-bundle-x.zip"})
        (spool / "results" / f"{rid}.zip").write_bytes(real_zip())
        resp = await bundle_client.get("/api/control/support-bundle-download", params={"id": rid})
        assert resp.status == 200
        files = zipfile.ZipFile(io.BytesIO(await resp.read())).namelist()
        assert files == ["bundle/manifest.json", "bundle/journal/all.log"]
        assert 'attachment; filename="support-bundle-x.zip"' in resp.headers["Content-Disposition"]
