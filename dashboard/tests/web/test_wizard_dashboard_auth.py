import secrets

from mining_dashboard.wizard import server as wizard


async def test_dashboard_session_cannot_authorize_any_wizard_mutation(
    tmp_path, monkeypatch, aiohttp_client
):
    monkeypatch.setenv("WIZARD_SPOOL", str(tmp_path / "spool"))
    monkeypatch.setenv("WIZARD_RESTORE", str(tmp_path / "restore"))
    monkeypatch.setenv("WIZARD_TOKEN", secrets.token_urlsafe())
    client = await aiohttp_client(wizard.make_app())
    checked = []
    for route in client.app.router.routes():
        if route.method != "POST" or route.resource.canonical == "/auth":
            continue
        path = route.resource.canonical
        response = await client.post(
            path,
            headers={"Cookie": "pithead_session=" + secrets.token_urlsafe()},
            allow_redirects=False,
        )
        assert response.status == 403, path
        checked.append(path)
    assert "/submit" in checked
    assert "/submit-restore" in checked
    assert "/retry" in checked
    assert not (tmp_path / "spool" / "submission-active").exists()
