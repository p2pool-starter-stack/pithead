# ruff: noqa: F403, F405
from tests.web._wizard_support import *  # noqa: F403


async def test_plaintext_restore_upload_stays_volatile(client, seeded, restore_spool):
    archive = b"\x1f\x8bplaintext-fixture-secret"
    await _auth(client)
    response = await client.post("/submit-restore", data=_archive_form(data=archive, passphrase=""))
    assert response.status == 200
    assert not (seeded / "restore-archive").exists()
    assert (restore_spool / "restore-archive").read_bytes() == archive


async def test_tls_auth_cookie_cannot_return_over_plain_http(spool):
    app = wizard.make_app(restore_enabled=True, secure_cookie=True)
    client = TestClient(TestServer(app))
    await client.start_server()
    try:
        response = await _auth(client)
        assert "Secure" in response.headers["Set-Cookie"]
    finally:
        await client.close()


async def test_plaintext_restore_cleanup_failure_is_generic(
    client, seeded, restore_spool, monkeypatch
):
    write = wizard._spool_write_text
    unlink = wizard.os.unlink

    def fail_ready(name, value, directory=None):
        if name == "submission-active":
            raise OSError("fixture ready-marker failure")
        write(name, value, directory)

    def fail_archive_cleanup(path):
        if str(path) == str(restore_spool / "restore-archive"):
            raise OSError("fixture volatile cleanup failure")
        unlink(path)

    monkeypatch.setattr(wizard, "_spool_write_text", fail_ready)
    monkeypatch.setattr(wizard.os, "unlink", fail_archive_cleanup)
    await _auth(client)
    response = await client.post(
        "/submit-restore", data=_archive_form(data=b"\x1f\x8bplaintext-fixture-secret")
    )
    body = await response.text()
    assert response.status == 500
    assert "could not be cleared safely" in body
    assert "plaintext-fixture-secret" not in body
    assert not (seeded / "restore-archive").exists()
    assert (restore_spool / "restore-archive").exists()


async def test_restore_clears_a_prior_secret_retry_snapshot(client, seeded):
    (seeded / "last-attempt.json").write_text('{"password":"abandoned-secret"}')
    await _auth(client)
    response = await client.post("/submit-restore", data=_archive_form())
    assert response.status == 200
    assert not (seeded / "last-attempt.json").exists()


async def test_restore_retry_snapshot_cleanup_failure_is_generic(client, seeded, monkeypatch):
    retry = seeded / "last-attempt.json"
    retry.write_text('{"password":"abandoned-secret"}')
    unlink = wizard.os.unlink

    def fail_retry_cleanup(path):
        if str(path) == str(retry):
            raise OSError("fixture retry cleanup failure")
        unlink(path)

    monkeypatch.setattr(wizard.os, "unlink", fail_retry_cleanup)
    await _auth(client)
    response = await client.post("/submit-restore", data=_archive_form())
    body = await response.text()
    assert response.status == 500
    assert "could not be cleared safely" in body
    assert "abandoned-secret" not in body


async def test_restore_is_refused_without_setup_tls(spool):
    app = wizard.make_app()
    client = TestClient(TestServer(app))
    await client.start_server()
    try:
        auth = await _auth(client)
        assert "Secure" not in auth.headers["Set-Cookie"]
        assert (await (await client.get("/api/wizard-state")).json())["restore_enabled"] is False
        response = await client.post("/submit-restore", data=_archive_form())
        assert response.status == 503
        assert "requires HTTPS" in (await response.json())["error"]
        assert not (spool / "restore-archive").exists()
    finally:
        await client.close()


def test_server_restart_clears_crash_left_secret_temps(spool, restore_spool):
    stale = (
        spool / ".config.json.crash",
        spool / ".last-attempt.json.crash",
        restore_spool / ".restore-passphrase.crash",
        restore_spool / ".restore-archive.crash",
    )
    for path in stale:
        path.write_text("crash-left-secret")
    wizard.make_app()
    assert not any(path.exists() for path in stale)


def test_server_restart_reports_unsafe_temp_cleanup_without_content(spool):
    stale = spool / ".config.json.crash"
    stale.mkdir()
    stale.joinpath("value").write_text("crash-left-secret")
    with pytest.raises(RuntimeError) as exc:
        wizard.make_app()
    assert "could not be cleared safely" in str(exc.value)
    assert "crash-left-secret" not in str(exc.value)
