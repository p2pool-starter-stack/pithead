# ruff: noqa: F403, F405
from tests.web._wizard_support import *  # noqa: F403


async def test_aiohttp_itself_refuses_a_body_over_client_max_size(spool, monkeypatch):
    # The explicit RESTORE_MAX_BYTES check above covers OUR refusal on a small, easy-to-build
    # body; this proves the OTHER half of the cap — aiohttp's own client_max_size (set from
    # the same constant, plus multipart-overhead slack, in make_app) answers 413 while the
    # body is still being READ, before submit_restore's own check ever runs. RESTORE_MAX_BYTES
    # is patched tiny so the slack-inclusive limit (~1 MiB) is crossable by an ordinary payload
    # rather than the real 64 MiB default.
    monkeypatch.setattr(wizard, "RESTORE_MAX_BYTES", 8)
    app = wizard.make_app()
    c = TestClient(TestServer(app))
    await c.start_server()
    try:
        await _auth(c)
        r = await c.post("/submit-restore", data=_archive_form(data=b"x" * 2_000_000))
        assert r.status == 413
    finally:
        await c.close()


async def test_restore_on_the_installer_takes_the_same_disk_gates(client, installer):
    # Identical erase discipline to a typed submission: an offered target, the exact retype.
    await _auth(client)
    r = await client.post(
        "/submit-restore", data=_archive_form(disk="sdz", confirm="sdz", wipe="keep")
    )
    assert r.status == 400
    assert not (installer / "restore-archive").exists()
    r = await client.post(
        "/submit-restore", data=_archive_form(disk="nvme0n1", confirm="nvme0n1", wipe="keep")
    )
    assert r.status == 200
    assert (installer / "install-request").read_text() == "nvme0n1\tkeep"
    assert (installer / "restore-archive").exists()
