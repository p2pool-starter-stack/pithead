"""Support-bundle routes (#4036): the POST shape that reaches the spool and the rules the
download route applies to the id it is given.

What the host does with the intent — unit membership, clamping, redaction, the size cap — is
proven in tests/stack against the real runner. What lives here: the CSRF gate, that only the
stated window travels, and that the download answers for exactly one class of result (applied,
naming an archive, that is still on disk) and 404s for everything else.
"""

import json
import uuid

import pytest

from mining_dashboard.service import control_service
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


def spooled(spool):
    files = list((spool / "requests").glob("*.json"))
    assert len(files) == 1, files
    return json.loads(files[0].read_text())


class TestSupportBundleDisabled:
    async def test_routes_404_when_the_control_channel_is_off(self, aiohttp_client, monkeypatch):
        monkeypatch.setattr(control_service.config, "DASHBOARD_CONTROL_ENABLED", False)
        sm = StateManager(db_path=":memory:")
        cli = await aiohttp_client(create_app(sm, {}))
        try:
            resp = await cli.post(
                "/api/control/support-bundle", headers=CONTROL_HEADERS, json={"hours": 24}
            )
            assert resp.status == 404
            resp = await cli.get("/api/control/support-bundle-download", params={"id": str(uuid.uuid4())})
            assert resp.status == 404
        finally:
            sm.close()


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

    @pytest.mark.parametrize("hours", [True, 0, -1, "24", None, [24]])
    async def test_a_malformed_window_is_a_400_and_spools_nothing(self, bundle_client, spool, hours):
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
        resp = await bundle_client.get(
            "/api/control/support-bundle-download", params={"id": rid}
        )
        assert resp.status == 404

    async def test_applied_without_the_archive_on_disk_is_a_404(self, bundle_client, spool):
        rid = str(uuid.uuid4())
        await self._result(spool, rid, {"status": "applied", "archive": "support-bundle-x.tar.gz"})
        resp = await bundle_client.get(
            "/api/control/support-bundle-download", params={"id": rid}
        )
        assert resp.status == 404

    async def test_applied_streams_the_spool_archive_under_its_named_filename(
        self, bundle_client, spool
    ):
        rid = str(uuid.uuid4())
        await self._result(spool, rid, {"status": "applied", "archive": "support-bundle-x.tar.gz"})
        (spool / "results" / f"{rid}.tar.gz").write_bytes(b"tarbytes")
        resp = await bundle_client.get(
            "/api/control/support-bundle-download", params={"id": rid}
        )
        assert resp.status == 200
        assert await resp.read() == b"tarbytes"
        assert 'attachment; filename="support-bundle-x.tar.gz"' in resp.headers["Content-Disposition"]
