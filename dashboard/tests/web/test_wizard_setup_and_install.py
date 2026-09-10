# ruff: noqa: F403, F405
from tests.web._wizard_support import *  # noqa: F403


async def test_shell_serves_without_auth_and_identifies_itself(client):
    # The tier-4 harness (and any curl) recognizes the page without executing the module.
    body = await (await client.get("/")).text()
    assert "Pithead setup" in body
    assert "/static/wizard/wizard.mjs" in body
    assert "/static/dashboard.css" in body  # same skin as the dashboard


async def test_bookmarked_steps_serve_the_same_shell(client):
    for path in ("/setup", "/install"):
        body = await (await client.get(path)).text()
        assert "/static/wizard/wizard.mjs" in body


async def test_static_assets_serve_with_module_mime(client):
    r = await client.get("/static/config/configsync.mjs")
    assert r.status == 200
    assert "javascript" in r.headers["Content-Type"]


@pytest.mark.parametrize(
    "typed",
    ["pit-X7KM2Q", "PIT-X7KM2Q", "pit-x7km2q", "X7KM2Q", "x7km2q", "  pit-X7KM2Q  "],
)
async def test_token_transcription_variants_all_pass(client, typed):
    # The operator copies from a console, often on a phone that autocapitalizes. Case and the
    # pit- prefix carry no entropy; neither may fail a correct transcription.
    r = await _auth(client, typed)
    assert r.status == 302
    assert "SameSite=Strict" in r.headers.get("Set-Cookie", "")


async def test_wrong_token_403(client):
    assert (await _auth(client, "pit-WRONGX")).status == 403


async def test_lockout_exits_3_after_max_failures(client):
    for _ in range(wizard.MAX_FAILURES):
        await _auth(client, "pit-WRONGX")
    assert client.server.app["exits"] == [wizard.EXIT_TOKEN_LOCKOUT]


async def test_lockout_response_is_429_with_console_hint(client):
    # Every failure before the last is the plain 403; only the one that trips the limit gets
    # the distinguishing status and the pointer to the console.
    for _ in range(wizard.MAX_FAILURES - 1):
        r = await _auth(client, "pit-WRONGX")
        assert r.status == 403
    r = await _auth(client, "pit-WRONGX")
    assert r.status == 429
    body = await r.json()
    assert "too many attempts" in body["error"].lower()
    assert "console" in body["error"].lower()


async def test_lockout_writes_the_429_before_the_exit_hook_runs(spool, monkeypatch):
    """Regression: the exit hook used to fire before the response was ever written, so the
    process could tear down before a single byte reached the browser. Track the real order of
    'bytes handed to the transport' vs 'exit hook called' rather than trusting that both merely
    happened."""
    order = []
    real_write_eof = web.Response.write_eof

    async def tracking_write_eof(self, *a, **kw):
        order.append("written")
        return await real_write_eof(self, *a, **kw)

    monkeypatch.setattr(web.Response, "write_eof", tracking_write_eof)

    app = wizard.make_app(exit_fn=lambda code: order.append("exit"))
    c = TestClient(TestServer(app))
    await c.start_server()
    try:
        for _ in range(wizard.MAX_FAILURES - 1):
            await _auth(c, "pit-WRONGX")
        r = await _auth(c, "pit-WRONGX")
        assert r.status == 429
    finally:
        await c.close()
    assert order[0] == "written"
    assert order.count("exit") == 1


def test_main_requires_token(monkeypatch):
    monkeypatch.delenv("WIZARD_TOKEN", raising=False)
    with pytest.raises(SystemExit) as e:
        wizard.main()
    assert e.value.code == 2


async def test_state_requires_auth(client):
    assert (await client.get("/api/wizard-state")).status == 401


async def test_state_carries_the_effective_config_and_mode(client, seeded):
    await _auth(client)
    s = await (await client.get("/api/wizard-state")).json()
    assert s["mode"] == "setup"
    assert s["config"]["monero"]["prune"] is True  # defaults filled in
    assert s["reference"]["p2pool"]["pool"] == "mini"
    assert s["error"] is None


async def test_state_switches_to_installer_mode_and_parses_disks(client, installer):
    await _auth(client)
    s = await (await client.get("/api/wizard-state")).json()
    assert s["mode"] == "installer"
    assert s["disks"][0] == {
        "name": "nvme0n1",
        "size": "931.5G",
        "model": "Samsung SSD 990",
        "serial": "S6P1NF0T",
        "state": "empty",
    }
    assert s["disks"][1]["state"] == "pithead-with-data"


async def test_disk_fields_with_markup_stay_data(client, spool):
    # The client renders objects via preact interpolation (auto-escaped); the server's job is
    # to keep hostile strings intact as DATA, not to sanitize them into something else.
    spool.joinpath("disks.tsv").write_text("sda\t1T\tACME <Turbo> & Co\tSN&1\tempty\n")
    await _auth(client)
    s = await (await client.get("/api/wizard-state")).json()
    assert s["disks"][0]["model"] == "ACME <Turbo> & Co"


async def test_a_rejected_attempt_comes_back_in_the_state(client, seeded):
    # No retyping a 95-character address to fix one field: the last attempt merges over the
    # defaults, and the host's rejection reason rides beside it.
    await _auth(client)
    cfg = {"monero": {"wallet_address": "4TYPO"}, "tari": {"wallet_address": "t"}}
    await client.post("/submit", data={"config": json.dumps(cfg)})
    seeded.joinpath("error.txt").write_text("bad wallet")
    s = await (await client.get("/api/wizard-state")).json()
    assert s["config"]["monero"]["wallet_address"] == "4TYPO"
    assert s["error"] == "bad wallet"


async def test_submitted_json_is_what_gets_written(client, seeded):
    await _auth(client)
    cfg = {"monero": {"wallet_address": "4XYZ"}, "tari": {"wallet_address": "t"}}
    r = await client.post("/submit", data={"config": json.dumps(cfg)})
    assert r.status == 200
    written = json.loads((seeded / "config.json").read_text())
    assert written["monero"]["wallet_address"] == "4XYZ"
    # The full attempt is kept for retry; no half-written temp files beside the atomic targets.
    assert json.loads((seeded / "last-attempt.json").read_text()) == cfg
    assert not [p for p in seeded.iterdir() if p.name.startswith(".")]


async def test_keys_at_their_default_are_not_written(client, seeded):
    # A config that pins every default would freeze them; the appliance receives improved
    # defaults through OS updates. Effective configuration is identical either way.
    await _auth(client)
    cfg = {
        "monero": {"wallet_address": "4XYZ", "prune": True, "mode": "local"},
        "tari": {"wallet_address": "t"},
        "p2pool": {"pool": "mini"},
        "tor": {"auto_heal": False},
    }
    await client.post("/submit", data={"config": json.dumps(cfg)})
    written = json.loads((seeded / "config.json").read_text())
    assert "prune" not in written["monero"]
    assert "mode" not in written["monero"]
    assert "p2pool" not in written
    assert written["monero"]["wallet_address"] == "4XYZ"


async def test_a_changed_default_is_written(client, seeded):
    await _auth(client)
    cfg = {"monero": {"wallet_address": "4XYZ", "prune": False}, "tari": {"wallet_address": "t"}}
    await client.post("/submit", data={"config": json.dumps(cfg)})
    assert json.loads((seeded / "config.json").read_text())["monero"]["prune"] is False


async def test_malformed_json_is_refused_without_spooling(client, seeded):
    await _auth(client)
    r = await client.post("/submit", data={"config": "{not json"})
    assert r.status == 400
    assert "Not valid JSON" in (await r.json())["error"]
    assert not (seeded / "config.json").exists()


async def test_a_bare_json_array_is_refused(client, seeded):
    await _auth(client)
    assert (await client.post("/submit", data={"config": "[1,2,3]"})).status == 400
    assert not (seeded / "config.json").exists()


async def test_submit_unauthed_redirects_and_writes_nothing(client, seeded):
    r = await client.post("/submit", data={"config": "{}"}, allow_redirects=False)
    assert r.status == 302
    assert not (seeded / "config.json").exists()


async def test_submit_clears_a_previous_error(client, seeded):
    seeded.joinpath("error.txt").write_text("old error")
    await _auth(client)
    cfg = {"monero": {"wallet_address": "4XYZ"}, "tari": {"wallet_address": "t"}}
    await client.post("/submit", data={"config": json.dumps(cfg)})
    assert not (seeded / "error.txt").exists()


async def test_form_fields_still_work_without_the_pane(client, seeded):
    await _auth(client)
    r = await client.post(
        "/submit",
        data={"monero_wallet": "4" + "A" * 94, "tari_wallet": "t", "pool": "mini", "config": ""},
    )
    assert r.status == 200
    cfg = json.loads((seeded / "config.json").read_text())
    assert cfg["monero"]["wallet_address"].startswith("4")


def test_a_machine_that_never_answered_the_tari_question_declines_it():
    # This read "tari.mode is local|remote only" until #1855 made that false: off is what a new
    # machine gets, written EXPLICITLY because an omitted key still parses as local.
    cfg = wizard.build_config({"monero_wallet": "4" + "A" * 94, "tari_wallet": ""})
    assert cfg["tari"] == {"mode": "off"}


def test_remote_monero_carries_ports_and_defaults_them():
    cfg = wizard.build_config(
        {
            "monero_wallet": "4" + "A" * 94,
            "tari_wallet": "t",
            "monero_mode": "remote",
            "monero_remote_host": "10.0.0.5",
            "monero_remote_rpc": "1234",
        }
    )
    assert cfg["monero"]["remote"] == {"host": "10.0.0.5", "rpc_port": 1234, "zmq_port": 18083}


def test_non_numeric_ports_fall_back_rather_than_crash():
    cfg = wizard.build_config(
        {
            "monero_wallet": "4" + "A" * 94,
            "tari_wallet": "t",
            "monero_mode": "remote",
            "monero_remote_host": "h",
            "monero_remote_rpc": "not-a-port",
        }
    )
    assert cfg["monero"]["remote"]["rpc_port"] == 18081


def test_prune_is_ignored_for_a_remote_node():
    # The chain lives on someone else's machine; claiming a shape for it is a lie.
    cfg = wizard.build_config(
        {
            "monero_wallet": "4" + "A" * 94,
            "tari_wallet": "t",
            "monero_mode": "remote",
            "monero_remote_host": "h",
            "prune": "false",
        }
    )
    assert "prune" not in cfg["monero"]


def test_alerts_are_omitted_unless_filled_in():
    base = {"monero_wallet": "4" + "A" * 94, "tari_wallet": "t"}
    cfg = wizard.build_config(base)
    assert "healthchecks" not in cfg and "telegram" not in cfg
    # Telegram needs both halves or neither — a half pair cannot deliver anything.
    assert "telegram" not in wizard.build_config({**base, "telegram_token": "123:ABC"})
    both = wizard.build_config({**base, "telegram_token": "123:ABC", "telegram_chat": "999"})
    assert both["telegram"] == {"enabled": True, "bot_token": "123:ABC", "chat_id": "999"}


def test_timezone_auto_is_the_default_and_never_pinned():
    base = {"monero_wallet": "4" + "A" * 94, "tari_wallet": "t"}
    assert "timezone" not in wizard.build_config({**base, "timezone": "auto"})["dashboard"]
    berlin = wizard.build_config({**base, "timezone": "Europe/Berlin"})
    assert berlin["dashboard"]["timezone"] == "Europe/Berlin"


async def test_target_must_be_one_the_host_offered(client, installer):
    await _auth(client)
    r = await _submit_install(client, disk="sdz")
    assert r.status == 400
    assert not (installer / "install-request").exists()
    # A rejected disk must not half-accept the config either — one page, one atomic answer.
    assert not (installer / "config.json.candidate").exists()


async def test_confirmation_must_match_the_chosen_disk(client, installer):
    await _auth(client)
    r = await _submit_install(client, confirm="nvme0n")
    assert r.status == 400
    assert not (installer / "install-request").exists()


async def test_unauthed_install_writes_nothing(client, installer):
    r = await client.post(
        "/submit",
        data={"config": _CFG, "disk": "nvme0n1", "confirm": "nvme0n1"},
        allow_redirects=False,
    )
    assert r.status == 302
    assert not (installer / "install-request").exists()


async def test_valid_request_is_written_and_carries_the_wipe_mode(client, installer):
    # sda is the fixture's disk with a previous install — the only kind where wipe means anything.
    await _auth(client)
    r = await _submit_install(client, disk="sda", wipe="data")
    assert r.status == 200
    assert (installer / "install-request").read_text() == "sda\tdata"


async def test_wipe_mode_defaults_to_keep_and_rejects_inventions(client, installer):
    await _auth(client)
    assert (await _submit_install(client, disk="sda")).status == 200
    assert (installer / "install-request").read_text() == "sda\tkeep"
    r = await _submit_install(client, disk="sda", wipe="everything")
    assert r.status == 400


async def test_keep_everything_submits_no_config_and_gets_no_handoff_machinery(client, installer):
    # The preserved config wins: a keep reinstall must write ONLY the install request. A config
    # candidate here would regenerate the dashboard password and show a card the machine never
    # serves — the exact bench-reported bug.
    await _auth(client)
    r = await client.post("/submit", data={"disk": "sda", "confirm": "sda", "wipe": "keep"})
    assert r.status == 200
    assert (installer / "install-request").read_text() == "sda\tkeep"
    assert not (installer / "config.json").exists()
    assert not (installer / "last-attempt.json").exists()


async def test_installer_state_serves_a_published_prefill(client, seeded, installer):
    # A reinstall's pre-fill: the HOST mounts the target's previous /data read-only, strips
    # the secrets and publishes the remainder as last-attempt.json — the state API is the only
    # channel to the page, and it must merge that pre-fill over the defaults exactly as the
    # pre-seed path's does.
    installer.joinpath("last-attempt.json").write_text(
        json.dumps({"monero": {"wallet_address": "4PREV"}, "tari": {"mode": "remote"}})
    )
    await _auth(client)
    s = await (await client.get("/api/wizard-state")).json()
    assert s["stage"] == "installer"
    assert s["config"]["monero"]["wallet_address"] == "4PREV"
    assert s["config"]["tari"]["mode"] == "remote"
    assert s["config"]["monero"]["prune"] is True  # the defaults still fill the gaps


async def test_a_broken_prefill_degrades_to_defaults_not_an_error(client, seeded, installer):
    # The pre-fill is pure convenience: an unparseable file means the form opens on the
    # documented defaults, with no error shown and nothing blocked.
    installer.joinpath("last-attempt.json").write_text("{not json")
    await _auth(client)
    r = await client.get("/api/wizard-state")
    assert r.status == 200
    s = await r.json()
    assert s["config"]["monero"]["wallet_address"] == ""
    assert s["error"] is None


async def test_keep_submit_leaves_a_published_prefill_alone(client, installer):
    # keep collapses the form and no config crosses. The pre-fill exists for the fresh/data
    # paths where the operator re-answers; an untouched keep must neither consume it nor
    # write anything beside the install request.
    installer.joinpath("last-attempt.json").write_text('{"monero": {"wallet_address": "4PREV"}}')
    await _auth(client)
    r = await client.post("/submit", data={"disk": "sda", "confirm": "sda", "wipe": "keep"})
    assert r.status == 200
    assert (installer / "install-request").read_text() == "sda\tkeep"
    assert not (installer / "config.json").exists()
    assert json.loads((installer / "last-attempt.json").read_text()) == {
        "monero": {"wallet_address": "4PREV"}
    }


async def test_keep_with_a_crafted_config_still_takes_the_keep_branch(client, installer):
    await _auth(client)
    r = await client.post(
        "/submit", data={"config": _CFG, "disk": "sda", "confirm": "sda", "wipe": "keep"}
    )
    assert r.status == 200
    assert not (installer / "config.json").exists()


async def test_fresh_disk_with_default_wipe_keep_is_a_normal_install(client, installer):
    # The client sends wipe=keep (its default) on EVERY submit; a blank disk must still take
    # the full config path — the gate caught this 400ing every fresh install.
    await _auth(client)
    r = await _submit_install(client, disk="nvme0n1", wipe="keep")
    assert r.status == 200
    assert (installer / "install-request").read_text() == "nvme0n1\tkeep"
    assert (installer / "config.json").exists()
