# ruff: noqa: F403, F405
import io
import json
import tarfile
import uuid

import pytest

from mining_dashboard.service import request_spool
from mining_dashboard.web.views.browser_bundle_views import SERVICES
from tests.web._server_support import *

HEADERS = {"X-Pithead-Control": "1", "X-Auth-User": "operator"}


def completed(spool, **overrides):
    rid = str(uuid.uuid4())
    result = {
        "id": rid,
        "kind": "diag-bundle",
        "status": "applied",
        "actor": "operator",
        "bundle": {
            "doctor": {"checks": [{"status": "ok", "message": "[redacted].onion"}]},
            "logs": {name: "bounded and redacted" for name in SERVICES},
        },
        **overrides,
    }
    (spool / "results" / f"{rid}.json").write_text(json.dumps(result))
    return rid, result


async def test_control_disabled_hides_both_bundle_routes(client):
    for endpoint in ("diag-bundle", "bundle-download"):
        assert (await client.post(f"/api/control/{endpoint}", headers=HEADERS)).status == 404


@pytest.mark.parametrize(
    "headers",
    [
        {},
        {"X-Pithead-Control": "1"},
        {"X-Auth-User": "operator"},
        {**HEADERS, "X-Auth-User": "bad/user"},
    ],
)
async def test_collection_and_download_require_csrf_and_identity(control_client, headers):
    for endpoint in ("diag-bundle", "bundle-download"):
        response = await control_client.post(f"/api/control/{endpoint}", headers=headers)
        assert response.status == 403


async def test_collection_spools_only_the_authenticated_fixed_action(control_client, control_spool):
    response = await control_client.post(
        "/api/control/diag-bundle",
        headers=HEADERS,
        json={"actor": "other", "container": "wallet-rpc"},
    )
    assert response.status == 202
    assert response.headers["Cache-Control"] == "no-store"
    rid = (await response.json())["id"]
    document = json.loads((control_spool / "requests" / f"{rid}.json").read_text())
    assert document == {"id": rid, "action": "diag-bundle", "actor": "operator"}


async def test_spool_failure_is_sanitized(control_client, monkeypatch):
    def fail(_request):
        raise OSError("private spool detail")

    monkeypatch.setattr(request_spool, "write", fail)
    response = await control_client.post("/api/control/diag-bundle", headers=HEADERS)
    assert response.status == 503
    assert "private spool detail" not in await response.text()


async def test_only_reviewed_browser_reports_become_private_fixed_name_tar_members(
    control_client, control_spool
):
    rid, result = completed(control_spool)
    response = await control_client.post(
        "/api/control/bundle-download", headers=HEADERS, json={"id": rid, "reviewed": True}
    )
    assert response.status == 200
    assert response.content_type == "application/gzip"
    assert response.headers["Cache-Control"] == "no-store"
    assert "pithead-browser-support.tar.gz" in response.headers["Content-Disposition"]
    with tarfile.open(fileobj=io.BytesIO(await response.read()), mode="r:gz") as archive:
        assert set(archive.getnames()) == {
            "doctor.json",
            *(f"logs/{name}.log" for name in SERVICES),
        }
        assert all(member.mode == 0o600 and member.isfile() for member in archive.getmembers())
        assert json.load(archive.extractfile("doctor.json")) == result["bundle"]["doctor"]
        assert b"[redacted].onion" in archive.extractfile("doctor.json").read()
    response = await control_client.get(f"/api/control/result?id={rid}", headers=HEADERS)
    assert response.status == 200
    assert response.headers["Cache-Control"] == "no-store"


async def test_other_session_cannot_preview_or_download_collected_reports(
    control_client, control_spool
):
    rid, _ = completed(control_spool)
    headers = {**HEADERS, "X-Auth-User": "someone-else"}
    assert (
        await control_client.get(f"/api/control/result?id={rid}", headers=headers)
    ).status == 403
    response = await control_client.post(
        "/api/control/bundle-download", headers=headers, json={"id": rid, "reviewed": True}
    )
    assert response.status == 403


@pytest.mark.parametrize(
    "body",
    [
        None,
        [],
        {},
        {"id": "bad", "reviewed": True},
        {"id": 5, "reviewed": True},
        {"id": str(uuid.uuid4()), "reviewed": False},
        {"id": str(uuid.uuid4()), "reviewed": True, "path": "archive"},
    ],
)
async def test_download_rejects_unreviewed_or_malformed_intents(control_client, body):
    response = await control_client.post("/api/control/bundle-download", headers=HEADERS, json=body)
    assert response.status == 400


@pytest.mark.parametrize("overrides", [{"kind": "backup"}, {"status": "failed"}])
async def test_cli_or_incomplete_archives_cannot_be_downloaded(
    control_client, control_spool, overrides
):
    rid, _ = completed(control_spool, **overrides)
    response = await control_client.post(
        "/api/control/bundle-download", headers=HEADERS, json={"id": rid, "reviewed": True}
    )
    assert response.status == 404


@pytest.mark.parametrize(
    "bundle",
    [
        None,
        {},
        {"doctor": {}, "logs": {}, "config": {}},
        {"doctor": [], "logs": {}},
        {"doctor": {}, "logs": {**{name: "" for name in SERVICES}, "wallet-rpc": "FORBIDDEN"}},
        {"doctor": {}, "logs": {name: 1 for name in SERVICES}},
        {"doctor": {}, "logs": {name: "x" * 65537 for name in SERVICES}},
        {"doctor": {"oversized": "x" * 131073}, "logs": {name: "" for name in SERVICES}},
    ],
)
async def test_bad_service_sets_paths_and_unbounded_reports_never_enter_archive(
    control_client, control_spool, bundle
):
    rid, _ = completed(control_spool, bundle=bundle)
    response = await control_client.post(
        "/api/control/bundle-download", headers=HEADERS, json={"id": rid, "reviewed": True}
    )
    assert response.status == 409


async def test_expired_bundle_cannot_be_downloaded(control_client):
    response = await control_client.post(
        "/api/control/bundle-download",
        headers=HEADERS,
        json={"id": str(uuid.uuid4()), "reviewed": True},
    )
    assert response.status == 404


async def test_failed_collection_preserves_host_reason_without_enabling_download(
    control_client, control_spool
):
    rid, _ = completed(
        control_spool, status="failed", error="A redacted report was not available.", bundle=None
    )
    response = await control_client.get(f"/api/control/result?id={rid}", headers=HEADERS)
    assert response.status == 200
    assert (await response.json())["error"] == "A redacted report was not available."
    response = await control_client.post(
        "/api/control/bundle-download", headers=HEADERS, json={"id": rid, "reviewed": True}
    )
    assert response.status == 404
