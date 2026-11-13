"""Coordinator hostname mapping and validation at the real wizard submit boundary."""

import json

import pytest
from aiohttp.test_utils import TestClient, TestServer

from mining_dashboard.wizard import server as wizard
from mining_dashboard.wizard.form import build_config
from mining_dashboard.wizard_config import MACHINE_NAME_RULE


def _consume_submission(spool):
    for name in ("config.json", "submission-staging", "submission-active"):
        spool.joinpath(name).unlink(missing_ok=True)


@pytest.fixture
async def hostname_client(tmp_path, monkeypatch):
    # The Docker test stage contains only dashboard/. Seed the relevant host
    # reference value as the other wizard fixtures do; the wizard must override it.
    tmp_path.joinpath("config.reference.json").write_text(
        json.dumps({"dashboard": {"host": "auto"}})
    )
    monkeypatch.setenv("WIZARD_SPOOL", str(tmp_path))
    monkeypatch.setenv("WIZARD_TOKEN", "pit-NAME01")
    async with TestClient(TestServer(wizard.make_app())) as client:
        await client.post("/auth", data={"token": "pit-NAME01"})
        yield client, tmp_path


async def test_new_machine_serves_named_default_and_form_fallback_maps_it(hostname_client):
    client, _spool = hostname_client
    state = await (await client.get("/api/wizard-state")).json()
    assert state["config"]["dashboard"]["host"] == "pithead"
    assert build_config({})["dashboard"]["host"] == "pithead"
    assert build_config({"machine_name": "garden-box"})["dashboard"]["host"] == "garden-box"


@pytest.mark.parametrize("name", ["garden-box", "a", "7", "a" * 63, "auto"])
async def test_valid_names_survive_submission_and_retry_prefill(hostname_client, name):
    client, spool = hostname_client
    result = await client.post(
        "/submit", data={"config": json.dumps({"dashboard": {"host": name}})}
    )
    assert result.status == 200
    assert json.loads(spool.joinpath("last-attempt.json").read_text())["dashboard"]["host"] == name


@pytest.mark.parametrize(
    "name",
    [
        "",
        "-bad",
        "bad-",
        "a" * 64,
        "has space",
        "bad_name",
        "x.local",
        "x\n",
        "é",
        123,
        None,
        "Box",
        "MiXeD",
        "localhost",
        "LocalHost",
    ],
)
async def test_bad_names_never_publish_a_candidate(hostname_client, name):
    client, spool = hostname_client
    result = await client.post(
        "/submit", data={"config": json.dumps({"dashboard": {"host": name}})}
    )
    assert result.status == 400
    assert "Name this machine" in (await result.json())["error"]
    if name == "localhost":
        assert (await result.json())["error"] == f"Invalid configuration: {MACHINE_NAME_RULE}"
    assert not spool.joinpath("config.json").exists()
    assert not spool.joinpath("install-request").exists()
    assert not spool.joinpath("last-attempt.json").exists()


async def test_missing_name_remains_compatible_and_bad_dashboard_shape_is_rejected(hostname_client):
    client, spool = hostname_client
    assert (await client.post("/submit", data={"config": "{}"})).status == 200
    _consume_submission(spool)
    result = await client.post("/submit", data={"config": '{"dashboard": []}'})
    assert result.status == 400


@pytest.mark.parametrize(
    "host", ["external.test", "old-name.local", "192.0.2.10", "2001:db8::1", ""]
)
async def test_unchanged_legacy_address_can_be_resubmitted_but_not_replaced_by_new_dns(
    hostname_client, host
):
    client, spool = hostname_client
    cfg = {"dashboard": {"host": host}}
    spool.joinpath("last-attempt.json").write_text(json.dumps(cfg))
    assert (await client.post("/submit", data={"config": json.dumps(cfg)})).status == 200
    assert json.loads(spool.joinpath("last-attempt.json").read_text())["dashboard"]["host"] == host
    _consume_submission(spool)
    result = await client.post("/submit", data={"config": '{"dashboard":{"host":"new.test"}}'})
    assert result.status == 400
    assert (
        await client.post("/submit", data={"config": '{"dashboard":{"host":"new-label"}}'})
    ).status == 200


@pytest.mark.parametrize(
    ("saved", "expected"), [("auto", "pithead"), (None, "pithead"), ("garden-box", "garden-box")]
)
async def test_state_prefills_the_default_name_over_saved_auto(hostname_client, saved, expected):
    client, spool = hostname_client
    cfg = {} if saved is None else {"dashboard": {"host": saved}}
    spool.joinpath("last-attempt.json").write_text(json.dumps(cfg))
    state = await (await client.get("/api/wizard-state")).json()
    assert state["config"]["dashboard"]["host"] == expected


@pytest.mark.parametrize(
    "bad", ["Shed-3", "shed_3", "shed.local", "-shed", "auto", "localhost", "a" * 64]
)
async def test_rig_worker_is_the_machine_name_and_follows_the_shared_rule(hostname_client, bad):
    client, spool = hostname_client
    result = await client.post(
        "/submit", data={"role": "rig", "rig_pool": "10.0.0.5:3333", "rig_worker": bad}
    )
    assert result.status == 400
    assert (await result.json())["error"] == MACHINE_NAME_RULE
    assert not spool.joinpath("rig-request.json").exists()


async def test_rig_worker_that_follows_the_rule_is_accepted(hostname_client):
    client, spool = hostname_client
    result = await client.post(
        "/submit", data={"role": "rig", "rig_pool": "10.0.0.5:3333", "rig_worker": "shed-3"}
    )
    assert result.status == 200
    assert json.loads(spool.joinpath("rig-request.json").read_text())["worker"] == "shed-3"
