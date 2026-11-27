"""Invalid raw control documents never become spooled intents."""

# ruff: noqa: F811 — imported pytest fixtures are resolved by name
import json

import pytest

from mining_dashboard.config import documents
from tests.web._server_support import app_data, control_client, control_spool  # noqa: F401

HEADERS = {"X-Pithead-Control": "1"}


@pytest.mark.parametrize(
    ("text", "path"),
    [
        ('{"config":{"monero":{},"monero":{}}}', "monero"),
        (
            '{"config":{"dashboard":{"auth":{"password":"first","password":"last"}}}}',
            "dashboard.auth.password",
        ),
        (
            '{"config":{"workers":{"list":[{"token":"first","token":"last"}]}}}',
            "workers.list[0].token",
        ),
    ],
)
async def test_preview_rejects_duplicate_document(control_client, control_spool, text, path):
    response = await control_client.post("/api/control/preview", data=text, headers=HEADERS)
    assert response.status == 400
    assert path in await response.text()
    assert not list((control_spool / "requests").iterdir())


@pytest.mark.parametrize(
    "path",
    [
        "dashboard.auth.password",
        "telegram.bot_token",
        "telegram.chat_id",
        "monero.node_username",
        "monero.node_password",
        "monero.view_key",
        "tari.view_key",
        "workers.api_token",
        "dashboard.host",
    ],
)
async def test_preview_rejects_placeholder_before_spooling(control_client, control_spool, path):
    cfg = "pAsTe_secret"
    for part in reversed(path.split(".")):
        cfg = {part: cfg}
    response = await control_client.post(
        "/api/control/preview", json={"config": cfg}, headers=HEADERS
    )
    assert response.status == 400
    text = await response.text()
    assert path in text and "pAsTe_secret" not in text
    assert not list((control_spool / "requests").iterdir())


async def test_commit_rejects_duplicate_intent_id(control_client, control_spool):
    text = (
        '{"id":"abcdefab-1234-4abc-8abc-123456789012","id":"abcdefab-1234-4abc-8abc-123456789013"}'
    )
    response = await control_client.post("/api/control/commit", data=text, headers=HEADERS)
    assert response.status == 400
    assert 'duplicate key "id"' in await response.text()
    assert not list((control_spool / "requests").iterdir())


@pytest.mark.parametrize(
    "cfg", ['{"monero":{},"monero":{}}', json.dumps({"telegram": {"bot_token": "YOUR_token"}})]
)
async def test_read_config_fails_before_masking_bad_document(control_client, control_spool, cfg):
    (control_spool / "config.json").write_text(cfg)
    response = await control_client.get("/api/config")
    assert response.status == 500
    assert "YOUR_token" not in await response.text()


@pytest.mark.parametrize("text", ["null", "[]", "not json"])
async def test_invalid_body_is_bad_request(control_client, control_spool, text):
    response = await control_client.post("/api/control/preview", data=text, headers=HEADERS)
    assert response.status == 400
    assert not list((control_spool / "requests").iterdir())


async def test_deep_document_is_bad_request(control_client, control_spool):
    text = '{"config":{"value":' + "[" * 1200 + "0" + "]" * 1200 + "}}"
    response = await control_client.post("/api/control/preview", data=text, headers=HEADERS)
    assert response.status == 400
    assert not list((control_spool / "requests").iterdir())


@pytest.mark.parametrize("endpoint", ["preview", "commit"])
@pytest.mark.parametrize(
    ("text", "diagnostic"),
    [
        ('{"config":{},"config":{}}', 'duplicate key "config" at the top level (path config)'),
        (
            '{"config":{"dashboard":{"auth":{"password":1,"password":2}}}}',
            'duplicate key "password" at config.dashboard.auth (path config.dashboard.auth.password)',
        ),
        (
            '{"config":{"dashboard":{"auth":{"password":"YOUR_secret"}}}}',
            "placeholder value at dashboard.auth.password",
        ),
        ("{", "Body must be JSON."),
        ("[]", "Body must be a JSON object."),
    ],
)
async def test_control_document_response_is_curated(
    control_client, control_spool, endpoint, text, diagnostic
):
    response = await control_client.post(f"/api/control/{endpoint}", data=text, headers=HEADERS)
    assert response.status == 400
    assert await response.text() == diagnostic
    assert not list((control_spool / "requests").iterdir())


@pytest.mark.parametrize("endpoint", ["preview", "commit"])
@pytest.mark.parametrize("known_defect", [False, True])
async def test_control_never_returns_exception_details(
    control_client, control_spool, monkeypatch, endpoint, known_defect
):
    def fail(_text):
        exc = (
            documents.ConfigDocumentError("dashboard.auth.password")
            if known_defect
            else ValueError()
        )
        exc.args = ("private parser details",)
        raise exc

    monkeypatch.setattr(documents, "loads", fail)
    response = await control_client.post(f"/api/control/{endpoint}", data="{}", headers=HEADERS)
    assert response.status == 400
    expected = (
        "placeholder value at dashboard.auth.password" if known_defect else "Body must be JSON."
    )
    assert await response.text() == expected
    assert not list((control_spool / "requests").iterdir())


async def test_read_config_reports_host_render_refusal(control_client, control_spool):
    (control_spool / "config.json").write_text(
        json.dumps({"_config_document_error": "placeholder value at dashboard.auth.password"})
    )
    response = await control_client.get("/api/config")
    assert response.status == 500
    assert "dashboard.auth.password" in await response.text()
    assert "placeholder value" in await response.text()
