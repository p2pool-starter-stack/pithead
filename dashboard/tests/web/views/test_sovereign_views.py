# ruff: noqa: F403, F405
from tests.web._server_support import *


async def test_preview_is_opt_in_and_keeps_the_current_dashboard(client, monkeypatch):
    monkeypatch.delenv("DASHBOARD_UI_PREVIEW", raising=False)
    assert (await client.get("/ui-preview")).status == 404
    monkeypatch.setenv("DASHBOARD_UI_PREVIEW", "1")
    response = await client.get("/ui-preview")
    assert response.status == 200
    assert response.headers["Cache-Control"] == "no-store"
    assert "/static/sovereign/main.mjs" in await response.text()
    assert "/static/dashboard.js" in await (await client.get("/")).text()
