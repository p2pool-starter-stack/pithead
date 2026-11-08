# ruff: noqa: F403, F405
from tests.web._wizard_support import *  # noqa: F403


@pytest.fixture(params=["setup", "installer", "stick"])
def failed_status(request, installer):
    if request.param == "setup":
        (installer / "disks.tsv").unlink()
    elif request.param == "stick":
        (installer / "stick").write_text("1")
    detail = "fixture node diagnostic\nfixture disk identity\nfixture installer stderr"
    (installer / "error.txt").write_text(detail)
    prefix = "Install failed" if request.param == "installer" else "Rejected"
    return prefix, detail


async def test_status_error_details_require_a_valid_session(client, failed_status):
    prefix, detail = failed_status
    response = await client.get("/status")
    body = await response.text()
    assert response.status == 200
    assert body.startswith(prefix)
    assert all(line not in body for line in detail.splitlines())
    assert response.headers["Cache-Control"] == "no-store"

    assert (await _auth(client)).status == 302
    response = await client.get("/status")
    body = await response.text()
    assert response.status == 200
    assert body.startswith(prefix)
    assert detail in body
    assert response.headers["Cache-Control"] == "no-store"


@pytest.mark.parametrize("session", ["invalid", "rotated", "disabled"])
async def test_status_error_details_reject_invalid_sessions(
    client, failed_status, monkeypatch, session
):
    prefix, detail = failed_status
    await _auth(client)
    if session == "invalid":
        client.session.cookie_jar.clear()
        client.session.cookie_jar.update_cookies({wizard.COOKIE: "invalid-session"})
    else:
        monkeypatch.setenv("WIZARD_TOKEN", "rotated-fixture-token" if session == "rotated" else "")
    response = await client.get("/status")
    body = await response.text()
    assert response.status == 200
    assert body.startswith(prefix)
    assert all(line not in body for line in detail.splitlines())
    assert response.headers["Cache-Control"] == "no-store"
