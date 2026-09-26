# ruff: noqa: F403, F405
import asyncio

from tests.web._wizard_support import *  # noqa: F403


async def test_aiohttp_itself_refuses_a_body_over_client_max_size(spool, monkeypatch):
    # The explicit RESTORE_MAX_BYTES check above covers OUR refusal on a small, easy-to-build
    # body; this proves the OTHER half of the cap — aiohttp's own client_max_size (set from
    # the same constant, plus multipart-overhead slack, in make_app) answers 413 while the
    # body is still being READ, before submit_restore's own check ever runs. RESTORE_MAX_BYTES
    # is patched tiny so the slack-inclusive limit (~1 MiB) is crossable by an ordinary payload
    # rather than the real 64 MiB default.
    monkeypatch.setattr(wizard, "RESTORE_MAX_BYTES", 8)
    app = wizard.make_app(restore_enabled=True)
    c = TestClient(TestServer(app))
    await c.start_server()
    try:
        await _auth(c)
        r = await c.post("/submit-restore", data=_archive_form(data=b"x" * 2_000_000))
        assert r.status == 413
    finally:
        await c.close()


async def test_restore_on_the_installer_takes_the_same_disk_gates(
    client, installer, restore_spool, monkeypatch
):
    # Identical erase discipline to a typed submission: an offered target, the exact retype.
    write_archive = wizard._spool_write_bytes

    def assert_prerequisites_then_write(name, data, directory=None):
        assert (restore_spool / "restore-passphrase").exists()
        assert (installer / "install-request").exists()
        write_archive(name, data, directory)

    monkeypatch.setattr(wizard, "_spool_write_bytes", assert_prerequisites_then_write)
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


async def test_restore_publish_failure_clears_every_half(
    client, installer, restore_spool, monkeypatch
):
    replace = wizard.os.replace

    def fail_archive(source, destination):
        if str(destination).endswith("restore-archive"):
            raise OSError("fixture publish failure")
        replace(source, destination)

    monkeypatch.setattr(wizard.os, "replace", fail_archive)
    await _auth(client)
    r = await client.post(
        "/submit-restore", data=_archive_form(disk="nvme0n1", confirm="nvme0n1", wipe="keep")
    )
    assert r.status == 500
    assert "hunter2" not in (await r.text())
    assert not (restore_spool / "restore-passphrase").exists()
    assert not (installer / "restore-archive").exists()
    assert not (installer / "install-attempt.json").exists()
    assert not (installer / "install-request").exists()
    assert not (installer / "submission-active").exists()
    assert not list(installer.glob(".restore-archive.*"))


async def test_oversize_passphrase_publishes_no_restore_state(client, installer, restore_spool):
    await _auth(client)
    response = await client.post(
        "/submit-restore",
        data=_archive_form(passphrase="x" * 4097, disk="nvme0n1", confirm="nvme0n1", wipe="all"),
    )
    assert response.status == 400
    assert not (restore_spool / "restore-passphrase").exists()
    assert not (installer / "install-request").exists()
    assert not (installer / "restore-archive").exists()


@pytest.mark.parametrize(
    ("data", "failed_name"),
    [
        (
            {
                "role": "rig",
                "rig_pool": "example.test:3333",
                "rig_password": "rig-secret",
            },
            "rig-request.json",
        ),
        ({"config": "{}", "auth_mode": "none"}, "config.json"),
    ],
)
async def test_typed_publication_failure_rolls_back_transaction(
    client, seeded, monkeypatch, data, failed_name
):
    replace = wizard.os.replace

    def fail_request(source, destination):
        if str(destination).endswith(failed_name):
            raise OSError("fixture publish failure")
        replace(source, destination)

    monkeypatch.setattr(wizard.os, "replace", fail_request)
    await _auth(client)
    response = await client.post("/submit", data=data)
    body = await response.text()
    assert response.status == 500
    assert "secret" not in body
    assert not (seeded / "submission-active").exists()
    assert not (seeded / "config.json").exists()
    assert not (seeded / "rig-request.json").exists()


@pytest.mark.parametrize(
    ("data", "published_name"),
    [
        ({"role": "rig", "rig_pool": "example.test:3333"}, "rig-request.json"),
        ({"config": "{}"}, "config.json"),
    ],
)
async def test_ready_marker_failure_rolls_back_published_request(
    client, seeded, monkeypatch, data, published_name
):
    write = wizard._spool_write_text

    def fail_ready(name, value, directory=None):
        if name == "submission-active":
            assert (seeded / published_name).exists()
            raise OSError("fixture ready-marker failure")
        write(name, value, directory)

    monkeypatch.setattr(wizard, "_spool_write_text", fail_ready)
    await _auth(client)
    response = await client.post("/submit", data=data)
    assert response.status == 500
    assert not (seeded / "submission-staging").exists()
    assert not (seeded / "submission-active").exists()
    assert not (seeded / published_name).exists()
    assert not (seeded / "auth-mode").exists()
    assert not (seeded / "role").exists()


async def test_restore_restates_stale_typed_login_intent(client, seeded):
    await _auth(client)
    typed = await client.post("/submit", data={"config": "{}", "auth_mode": "none"})
    assert typed.status == 200
    for name in ("config.json", "submission-staging", "submission-active"):
        (seeded / name).unlink()
    assert (seeded / "auth-mode").read_text() == "none"
    restore = await client.post("/submit-restore", data=_archive_form())
    assert restore.status == 200
    assert not (seeded / "auth-mode").exists()


async def test_restore_text_publish_failure_removes_its_private_temp(
    client, restore_spool, monkeypatch
):
    replace = wizard.os.replace

    def fail_passphrase(source, destination):
        if str(destination).endswith("restore-passphrase"):
            raise OSError("fixture publish failure")
        replace(source, destination)

    monkeypatch.setattr(wizard.os, "replace", fail_passphrase)
    await _auth(client)
    r = await client.post("/submit-restore", data=_archive_form())
    assert r.status == 500
    assert not list(restore_spool.glob(".restore-passphrase.*"))


async def test_restore_publish_reports_real_cleanup_failure_without_secret(
    client, seeded, monkeypatch
):
    replace = wizard.os.replace
    unlink = wizard.os.unlink

    def fail_archive(source, destination):
        if str(destination).endswith("restore-archive"):
            raise OSError("fixture publish failure")
        replace(source, destination)

    def fail_temp_cleanup(path):
        if wizard.os.path.basename(path).startswith(".restore-archive."):
            raise OSError("fixture cleanup failure")
        unlink(path)

    monkeypatch.setattr(wizard.os, "replace", fail_archive)
    monkeypatch.setattr(wizard.os, "unlink", fail_temp_cleanup)
    await _auth(client)
    r = await client.post("/submit-restore", data=_archive_form())
    body = await r.text()
    assert r.status == 500
    assert "could not be cleared safely" in body
    assert "hunter2" not in body
    assert list(seeded.glob(".restore-archive.*"))


async def test_concurrent_restore_uploads_cannot_cross_generations(client):
    started = asyncio.Event()
    release = asyncio.Event()

    async def slow_archive():
        started.set()
        await release.wait()
        yield b"Salted__first-generation"

    form = FormData()
    form.add_field(
        "archive",
        slow_archive(),
        filename="backup.tar.gz.enc",
        content_type="application/octet-stream",
    )
    form.add_field("passphrase", "first")
    await _auth(client)
    first = asyncio.create_task(client.post("/submit-restore", data=form))
    await asyncio.wait_for(started.wait(), 1)
    second = asyncio.create_task(
        client.post("/submit-restore", data=_archive_form(passphrase="second"))
    )
    await asyncio.sleep(0)
    release.set()
    first_response, second_response = await asyncio.gather(first, second)
    assert first_response.status == 200
    assert second_response.status == 409


async def test_typed_submit_cannot_replace_a_restore_transaction(client, installer):
    started = asyncio.Event()
    release = asyncio.Event()

    async def slow_archive():
        started.set()
        await release.wait()
        yield b"Salted__restore-generation"

    form = FormData()
    form.add_field("archive", slow_archive(), filename="backup.tar.gz.enc")
    form.add_field("passphrase", "first")
    form.add_field("disk", "nvme0n1")
    form.add_field("confirm", "nvme0n1")
    form.add_field("wipe", "keep")
    await _auth(client)
    restore = asyncio.create_task(client.post("/submit-restore", data=form))
    await asyncio.wait_for(started.wait(), 1)
    typed = asyncio.create_task(
        client.post(
            "/submit",
            data={
                "role": "rig",
                "rig_pool": "example.test:3333",
                "disk": "nvme0n1",
                "confirm": "nvme0n1",
                "wipe": "all",
            },
        )
    )
    release.set()
    restore_response, typed_response = await asyncio.gather(restore, typed)
    assert restore_response.status == 200
    assert typed_response.status == 409
    assert (installer / "install-request").read_text() == "nvme0n1\tkeep"
    assert not (installer / "rig-request.json").exists()


async def test_restore_cannot_replace_a_typed_transaction(client, installer):
    await _auth(client)
    typed = await client.post(
        "/submit",
        data={
            "role": "rig",
            "rig_pool": "example.test:3333",
            "disk": "nvme0n1",
            "confirm": "nvme0n1",
            "wipe": "all",
        },
    )
    (installer / "rig-request.json").unlink()
    (installer / "install-request").unlink()
    (installer / "applied").write_text("1")
    (installer / "handoff.json").write_text("{}")
    restore = await client.post(
        "/submit-restore",
        data=_archive_form(disk="nvme0n1", confirm="nvme0n1", wipe="all"),
    )
    assert typed.status == 200
    assert restore.status == 409
    assert (installer / "submission-active").exists()
    assert not (installer / "restore-archive").exists()


async def test_restore_inflight_refuses_a_new_generation(client, seeded):
    await _auth(client)
    assert (await client.post("/submit-restore", data=_archive_form())).status == 200
    (seeded / "restore-archive").unlink()
    (seeded / "restore-inflight").write_text("1")
    r = await client.post("/submit-restore", data=_archive_form(passphrase="replacement"))
    assert r.status == 409
    assert "processed" in (await r.json())["error"]


async def test_orphan_passphrase_is_cleared_before_restore_retry(client, restore_spool):
    (restore_spool / "restore-passphrase").write_text("orphan-secret")
    await _auth(client)
    response = await client.post("/submit-restore", data=_archive_form())
    assert response.status == 200
    assert (restore_spool / "restore-passphrase").read_text() == "hunter2"


async def test_orphan_passphrase_clears_its_disk_trigger_before_invalid_retry(
    client, installer, restore_spool
):
    (restore_spool / "restore-passphrase").write_text("orphan-secret")
    (installer / "install-request").write_text("nvme0n1\tall")
    await _auth(client)
    response = await client.post(
        "/submit-restore", data=_archive_form(disk="missing", confirm="missing", wipe="keep")
    )
    assert response.status == 400
    assert not (installer / "install-request").exists()
    assert not (restore_spool / "restore-passphrase").exists()


async def test_orphan_passphrase_cleanup_failure_is_generic(client, restore_spool, monkeypatch):
    (restore_spool / "restore-passphrase").write_text("orphan-secret")
    unlink = wizard.os.unlink

    def fail_orphan(path):
        if str(path).endswith("restore-passphrase"):
            raise OSError("fixture cleanup failure")
        unlink(path)

    monkeypatch.setattr(wizard.os, "unlink", fail_orphan)
    await _auth(client)
    response = await client.post("/submit-restore", data=_archive_form())
    body = await response.text()
    assert response.status == 500
    assert "could not be cleared safely" in body
    assert "orphan-secret" not in body
