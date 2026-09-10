# ruff: noqa: F403, F405
from tests.web._wizard_support import *  # noqa: F403


async def test_keep_on_a_blank_disk_falls_through_to_a_normal_install(client, installer):
    # The page never offers keep on a blank disk; a bare submit there is treated as a fresh
    # install whose (empty) config the HOST rejects with a named reason — the server does not
    # guess intent. The no-JS form path made an early 400 impossible to distinguish from a
    # legitimate field submit; the gate caught exactly that as a broken fresh install.
    await _auth(client)
    r = await client.post("/submit", data={"disk": "nvme0n1", "confirm": "nvme0n1", "wipe": "keep"})
    assert r.status == 200
    assert (installer / "install-request").read_text() == "nvme0n1\tkeep"
    assert (installer / "config.json").exists()


async def test_wipe_is_normalized_to_keep_on_a_disk_with_nothing_to_wipe(client, installer):
    # nvme0n1 is empty in the fixture: "wipe" is meaningless there, and the page never offers
    # it — a crafted request is normalized rather than trusted.
    await _auth(client)
    r = await _submit_install(client, disk="nvme0n1", wipe="all")
    assert r.status == 200
    assert (installer / "install-request").read_text() == "nvme0n1\tkeep"


async def test_status_narrates_setup(client, spool):
    assert "Waiting" in await (await client.get("/status")).text()
    spool.joinpath("error.txt").write_text("bad wallet")
    assert "Rejected: bad wallet" in await (await client.get("/status")).text()
    spool.joinpath("error.txt").unlink()
    spool.joinpath("applied").write_text("1")
    assert "Provisioned" in await (await client.get("/status")).text()


async def test_status_narrates_the_install_and_the_shutdown(client, installer):
    assert "Copying" in await (await client.get("/status")).text()
    (installer / "installed").write_text("1")
    body = await (await client.get("/status")).text()
    # The shutdown IS the completion, and the order must survive rewording: off, then stick.
    assert body.startswith("Installed")
    assert body.lower().index("go dark") < body.lower().index("remove the usb stick")


def test_plain_http_is_the_fallback_when_no_cert_is_supplied(monkeypatch):
    # A machine that could not mint a certificate must still serve a setup page, not nothing.
    monkeypatch.setenv("WIZARD_TOKEN", "pit-X7KM2Q")
    monkeypatch.delenv("WIZARD_TLS_CERT", raising=False)
    started = {}
    monkeypatch.setattr(wizard.web, "run_app", lambda app, **kw: started.update(kw))
    wizard.main()
    assert started["port"] == 8000


def test_tls_is_used_when_both_halves_exist(monkeypatch, tmp_path):
    cert, key = tmp_path / "c.pem", tmp_path / "k.pem"
    cert.write_text("x")
    key.write_text("y")
    monkeypatch.setenv("WIZARD_TOKEN", "pit-X7KM2Q")
    monkeypatch.setenv("WIZARD_TLS_CERT", str(cert))
    monkeypatch.setenv("WIZARD_TLS_KEY", str(key))
    seen = {}

    def fake_run(coro):
        coro.close()
        seen["ran"] = True

    monkeypatch.setattr(wizard.asyncio, "run", fake_run)
    monkeypatch.setattr(wizard.web, "run_app", lambda *a, **k: seen.setdefault("plain", True))
    wizard.main()
    assert seen.get("ran") and "plain" not in seen


def test_a_missing_key_falls_back_rather_than_crashing(monkeypatch, tmp_path):
    cert = tmp_path / "c.pem"
    cert.write_text("x")
    monkeypatch.setenv("WIZARD_TOKEN", "pit-X7KM2Q")
    monkeypatch.setenv("WIZARD_TLS_CERT", str(cert))
    monkeypatch.setenv("WIZARD_TLS_KEY", str(tmp_path / "absent.pem"))
    started = {}
    monkeypatch.setattr(wizard.web, "run_app", lambda app, **kw: started.update(kw))
    wizard.main()
    assert started["port"] == 8000


async def test_plain_port_redirects_to_tls_keeping_the_host_used():
    # Someone typing a bare address lands on :80; a dead port there reads as a broken machine.
    req = _plain_request("pithead.local")
    with pytest.raises(web.HTTPMovedPermanently) as exc:
        await wizard._redirect_to_tls(req)
    assert exc.value.location == "https://pithead.local/setup"


async def test_plain_port_keeps_the_address_the_request_arrived_on():
    # A bare LAN address is the other documented way in, and the socket proves the box owns it.
    req = _plain_request("192.168.1.10")
    with pytest.raises(web.HTTPMovedPermanently) as exc:
        await wizard._redirect_to_tls(req)
    assert exc.value.location == "https://192.168.1.10/setup"


async def test_plain_port_refuses_to_bounce_setup_to_a_forged_host():
    # The Host header belongs to whoever made the request. Honouring it turns :80 into an open
    # redirector on the one screen where the operator types the dashboard password — reachable
    # through a name that resolves here (rebinding, or a LAN whose DNS is not trustworthy), with
    # the address bar still showing what they typed. It must land back on this machine.
    req = _plain_request("evil.example")
    with pytest.raises(web.HTTPMovedPermanently) as exc:
        await wizard._redirect_to_tls(req)
    assert exc.value.location == "https://192.168.1.10/setup"


async def test_plain_port_redirect_survives_a_transport_that_cannot_say():
    # Never leave the operator with a broken link: with no socket to fall back to, the documented
    # mDNS name is the one address every pithead answers to.
    req = _plain_request("evil.example", sockname=None)
    with pytest.raises(web.HTTPMovedPermanently) as exc:
        await wizard._redirect_to_tls(req)
    assert exc.value.location == "https://pithead.local/setup"


async def test_plain_port_redirect_brackets_an_ipv6_address():
    # https://fd00::1/setup is not a URL; the brackets are what make it one.
    req = _plain_request("[fd00::1]", sockname=("fd00::1", 80, 0, 0))
    with pytest.raises(web.HTTPMovedPermanently) as exc:
        await wizard._redirect_to_tls(req)
    assert exc.value.location == "https://[fd00::1]/setup"


async def test_handoff_requires_auth(client, spool):
    spool.joinpath("handoff.json").write_text('{"username":"admin"}')
    assert (await client.get("/api/handoff")).status == 401


async def test_handoff_404s_until_the_host_publishes_it(client, spool):
    await _auth(client)
    assert (await client.get("/api/handoff")).status == 404


async def test_handoff_serves_what_the_host_published(client, spool):
    spool.joinpath("handoff.json").write_text(
        json.dumps(
            {"username": "admin", "password": "x" * 32, "dashboard": "https://pithead.local"}
        )
    )
    await _auth(client)
    h = await (await client.get("/api/handoff")).json()
    assert h["username"] == "admin" and len(h["password"]) == 32


async def test_ack_needs_auth_and_a_published_handoff(client, spool):
    r = await client.post("/handoff-ack", allow_redirects=False)
    assert r.status == 302
    await _auth(client)
    assert (await client.post("/handoff-ack")).status == 400  # nothing published yet
    assert not (spool / "handoff-ack").exists()
    spool.joinpath("handoff.json").write_text("{}")
    assert (await client.post("/handoff-ack")).status == 200
    assert (spool / "handoff-ack").read_text() == "1"


async def test_stage_is_setup_before_anything_is_submitted(client, seeded):
    await _auth(client)
    assert (await (await client.get("/api/wizard-state")).json())["stage"] == "setup"


async def test_stage_becomes_handoff_when_credentials_are_published(client, seeded):
    seeded.joinpath("applied").write_text("1")
    seeded.joinpath("handoff.json").write_text(json.dumps({"username": "admin", "password": "p"}))
    await _auth(client)
    s = await (await client.get("/api/wizard-state")).json()
    assert s["stage"] == "handoff"
    # The card's contents ride the SAME payload the page already polls — no second fetch to race.
    assert s["handoff"]["username"] == "admin"


async def test_stage_becomes_done_after_the_ack(client, seeded):
    seeded.joinpath("handoff.json").write_text("{}")
    seeded.joinpath("handoff-ack").write_text("1")
    await _auth(client)
    s = await (await client.get("/api/wizard-state")).json()
    assert s["stage"] == "done"
    assert s["handoff"] is None  # nothing left to save


async def test_stage_is_done_while_provisioning_so_a_refresh_cannot_re_edit(client, seeded):
    seeded.joinpath("applied").write_text("1")
    await _auth(client)
    assert (await (await client.get("/api/wizard-state")).json())["stage"] == "done"


async def test_stage_reports_installing_once_the_install_starts(client, installer):
    # The HOST writes this marker when it begins the erase (after the credentials ack) —
    # a pending install-request alone is still editable and must stay on the form.
    installer.joinpath("installing").write_text("1")
    await _auth(client)
    assert (await (await client.get("/api/wizard-state")).json())["stage"] == "installing"


async def test_stage_stays_on_the_combined_form_while_a_request_is_pending(client, installer):
    installer.joinpath("install-request").write_text("sda\tkeep")
    await _auth(client)
    assert (await (await client.get("/api/wizard-state")).json())["stage"] == "installer"


async def test_ack_on_the_installer_means_installing_not_provisioning(client, installer):
    # Same ack, two meanings: on an installed machine it releases provisioning ("done"), on the
    # installation medium it releases the erase — the page must show the switch-off steps.
    installer.joinpath("handoff-ack").write_text("1")
    await _auth(client)
    assert (await (await client.get("/api/wizard-state")).json())["stage"] == "installing"


async def test_rig_submit_writes_the_request_and_role_and_no_config(client, seeded):
    await _auth(client)
    r = await client.post(
        "/submit",
        data={
            "role": "rig",
            "rig_pool": "pithead.local:3333",
            "rig_worker": "shed-3",
            "rig_password": "fixture-stratum-pw",
        },
    )
    assert r.status == 200
    req = json.loads((seeded / "rig-request.json").read_text())
    assert req == {
        "pool": "pithead.local:3333",
        "worker": "shed-3",
        "stratum_password": "fixture-stratum-pw",
    }
    assert (seeded / "role").read_text() == "rig"
    # None of the coordinator machinery: no config candidate, no retry attempt.
    assert not (seeded / "config.json").exists()
    assert not (seeded / "last-attempt.json").exists()


async def test_rig_pool_must_look_like_host_port(client, seeded):
    await _auth(client)
    for bad in ("", "pithead.local", "pithead.local:", ":3333", "pithead.local:zzz"):
        r = await client.post("/submit", data={"role": "rig", "rig_pool": bad})
        assert r.status == 400, bad
        assert "host:port" in (await r.json())["error"]
    assert not (seeded / "rig-request.json").exists()


async def test_rig_empty_worker_and_password_are_omitted(client, seeded):
    # The HOST fills the worker default (its own hostname); an empty password is no password.
    await _auth(client)
    await client.post("/submit", data={"role": "rig", "rig_pool": "10.0.0.5:3333"})
    assert json.loads((seeded / "rig-request.json").read_text()) == {"pool": "10.0.0.5:3333"}


async def test_rig_on_the_installer_takes_the_same_disk_gates(client, installer):
    # Identical erase discipline in every role: offered target, exact retype, fixed wipe set.
    await _auth(client)
    base = {"role": "rig", "rig_pool": "10.0.0.5:3333"}
    assert (
        await client.post("/submit", data={**base, "disk": "sdz", "confirm": "sdz"})
    ).status == 400
    r = await client.post("/submit", data={**base, "disk": "nvme0n1", "confirm": "nvme0n"})
    assert r.status == 400
    # A rejected disk half-accepts nothing — one page, one atomic answer.
    assert not (installer / "install-request").exists()
    assert not (installer / "rig-request.json").exists()
    r = await client.post("/submit", data={**base, "disk": "nvme0n1", "confirm": "nvme0n1"})
    assert r.status == 200
    assert (installer / "install-request").read_text() == "nvme0n1\tkeep"
    assert (installer / "rig-request.json").exists()


async def test_run_from_this_stick_is_first_class_for_the_rig_role_only(client, installer):
    # "usb" is not a disk: nothing is erased, so NO install request — the answers still travel.
    await _auth(client)
    r = await client.post(
        "/submit", data={"role": "rig", "rig_pool": "10.0.0.5:3333", "disk": "usb"}
    )
    assert r.status == 200
    assert not (installer / "install-request").exists()
    assert (installer / "rig-request.json").exists()
    # Any other role naming "usb" hits the inventory gate: the host never offered it.
    r = await client.post("/submit", data={"config": _CFG, "disk": "usb", "confirm": "usb"})
    assert r.status == 400


async def test_rig_keep_on_a_preserved_disk_stays_a_keep(client, installer):
    # keep means KEEP in every role: the survivor config wins, no role change crosses.
    await _auth(client)
    r = await client.post(
        "/submit",
        data={
            "role": "rig",
            "rig_pool": "10.0.0.5:3333",
            "disk": "sda",
            "confirm": "sda",
            "wipe": "keep",
        },
    )
    assert r.status == 200
    assert (installer / "install-request").read_text() == "sda\tkeep"
    assert not (installer / "rig-request.json").exists()
    assert not (installer / "role").exists()


async def test_state_carries_the_hosts_rig_defaults_and_fails_open(client, seeded):
    await _auth(client)
    s = await (await client.get("/api/wizard-state")).json()
    assert s["rig_defaults"] == {}  # nothing published — the fields open empty
    seeded.joinpath("rig-defaults.json").write_text(
        '{"pool": "pithead.local:3333", "worker": "hp"}'
    )
    s = await (await client.get("/api/wizard-state")).json()
    assert s["rig_defaults"] == {"pool": "pithead.local:3333", "worker": "hp"}
    seeded.joinpath("rig-defaults.json").write_text("{broken")
    s = await (await client.get("/api/wizard-state")).json()
    assert s["rig_defaults"] == {}


async def test_status_narrates_the_rig_save_without_promising_a_dashboard(client, spool):
    spool.joinpath("role").write_text("rig")
    spool.joinpath("applied").write_text("1")
    body = await (await client.get("/status")).text()
    assert "Rig settings saved" in body
    assert "dashboard" not in body.lower()  # a rig serves none — never point at one
    # The boot leg is real: the last page this machine ever shows says the miner is starting,
    # and names where the operator will actually see it.
    assert "miner is starting" in body
    assert "Workers view" in body


async def test_rig_submit_clears_a_previous_error(client, seeded):
    seeded.joinpath("error.txt").write_text("old error")
    await _auth(client)
    await client.post("/submit", data={"role": "rig", "rig_pool": "10.0.0.5:3333"})
    assert not (seeded / "error.txt").exists()


async def test_unauthed_rig_submit_writes_nothing(client, seeded):
    r = await client.post(
        "/submit", data={"role": "rig", "rig_pool": "10.0.0.5:3333"}, allow_redirects=False
    )
    assert r.status == 302
    assert not (seeded / "rig-request.json").exists()


async def test_auth_mode_rides_beside_the_config(client, seeded):
    # "no login" is an empty password, which is also what "not chosen" looks like — the choice
    # cannot be encoded in the config without colliding with a real one.
    await _auth(client)
    cfg = {"monero": {"wallet_address": "4XYZ"}, "tari": {"wallet_address": "t"}}
    await client.post("/submit", data={"config": json.dumps(cfg), "auth_mode": "none"})
    assert (seeded / "auth-mode").read_text() == "none"


async def test_an_unknown_auth_mode_is_ignored(client, seeded):
    await _auth(client)
    cfg = {"monero": {"wallet_address": "4XYZ"}, "tari": {"wallet_address": "t"}}
    await client.post("/submit", data={"config": json.dumps(cfg), "auth_mode": "whatever"})
    assert not (seeded / "auth-mode").exists()


async def test_restore_writes_the_archive_and_passphrase_and_clears_a_previous_error(
    client, seeded
):
    seeded.joinpath("error.txt").write_text("old error")
    await _auth(client)
    r = await client.post("/submit-restore", data=_archive_form())
    assert r.status == 200
    assert (seeded / "restore-archive").read_bytes() == b"Salted__fixture-ciphertext"
    assert (seeded / "restore-passphrase").read_text() == "hunter2"
    assert not (seeded / "error.txt").exists()


async def test_restore_requires_an_uploaded_archive(client, seeded):
    await _auth(client)
    form = FormData()
    form.add_field("passphrase", "hunter2")  # noqa: S106
    r = await client.post("/submit-restore", data=form)
    assert r.status == 400
    assert "archive" in (await r.json())["error"]
    assert not (seeded / "restore-archive").exists()


async def test_restore_oversize_upload_is_refused_without_spooling(client, seeded, monkeypatch):
    monkeypatch.setattr(wizard, "RESTORE_MAX_BYTES", 8)
    await _auth(client)
    r = await client.post("/submit-restore", data=_archive_form(data=b"more than eight bytes"))
    assert r.status == 400
    assert "too large" in (await r.json())["error"]
    assert not (seeded / "restore-archive").exists()


async def test_restore_unauthed_redirects_and_writes_nothing(client, seeded):
    r = await client.post("/submit-restore", data=_archive_form(), allow_redirects=False)
    assert r.status == 302
    assert not (seeded / "restore-archive").exists()
