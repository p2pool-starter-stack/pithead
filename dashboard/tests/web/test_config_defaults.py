import json
from pathlib import Path

import pytest

from mining_dashboard.config.defaults import (
    TABLE,
    default_of,
    effective_defaults,
    new_install_defaults,
)
from mining_dashboard.service import control_service
from mining_dashboard.wizard.defaults import explicit_wizard_config, new_machine_answers
from mining_dashboard.wizard.form import build_config


@pytest.mark.parametrize("platform", ["diy", "appliance"])
@pytest.mark.parametrize("path", TABLE["materialize"])
def test_all_new_install_paths_materialize_the_platform_default(platform, path):
    block, key = path.split(".")
    expected = default_of(path, platform)
    answers = new_machine_answers({}, [], platform)
    for config in (
        new_install_defaults(platform),
        build_config({}, platform=platform),
        answers,
        explicit_wizard_config(answers, effective_defaults(legacy=True)),
    ):
        assert config[block][key] == expected


@pytest.mark.parametrize("platform", ["diy", "appliance"])
@pytest.mark.parametrize("path", TABLE["materialize"])
def test_explicit_browser_answers_survive_default_stripping(platform, path):
    block, key = path.split(".")
    cfg = new_machine_answers({}, [], platform)
    value = cfg[block][key]
    value = not value if isinstance(value, bool) else "chosen"
    cfg[block][key] = value
    assert explicit_wizard_config(cfg, effective_defaults(legacy=True))[block][key] == value


@pytest.mark.parametrize("platform", ["diy", "appliance"])
def test_no_javascript_preserves_explicit_miner_and_host_answers(platform):
    cfg = build_config({"local_miner": "false", "machine_name": "chosen"}, platform=platform)
    assert cfg["local_miner"]["enabled"] is False
    assert cfg["dashboard"]["host"] == "chosen"
    assert build_config({"local_miner": "on"}, platform=platform)["local_miner"]["enabled"] is True


@pytest.mark.parametrize("entry", TABLE["LEGACY_ABSENT"], ids=lambda e: e["path"])
def test_legacy_absent_values_are_named_and_retired_by_migration(entry):
    platform = entry.get("platform", "diy")
    assert default_of(entry["path"], platform, legacy=True) == entry["value"]
    assert default_of(entry["path"], platform) != entry["value"]
    assert entry["retired_by"] == "pithead#3576"


@pytest.mark.parametrize(
    "path,expected", [("local_miner.enabled", False), ("dashboard.host", "auto")]
)
@pytest.mark.parametrize("explicit", [False, True])
def test_existing_appliance_editor_preserves_v2_absent_values(
    tmp_path, monkeypatch, path, expected, explicit
):
    reference = effective_defaults(legacy=True)
    golden = json.loads(
        (Path(__file__).parents[1] / "fixtures/config-2.0.0/reference.json").read_text()
    )
    block, key = path.split(".")
    assert reference[block][key] == golden[block][key] == expected
    host = {
        "monero": {"wallet_address": "fixture-wallet"},
        "tari": {"wallet_address": "fixture-tari"},
    }
    block, key = path.split(".")
    if explicit:
        host[block] = {key: True if isinstance(expected, bool) else "chosen"}
    reference_path, host_path = tmp_path / "reference.json", tmp_path / "config.json"
    reference_path.write_text(json.dumps(reference))
    host_path.write_text(json.dumps(host))
    monkeypatch.setattr(control_service.config, "HOST_REFERENCE_PATH", str(reference_path))
    monkeypatch.setattr(control_service.config, "HOST_CONFIG_PATH", str(host_path))
    cfg = control_service.read_config()
    assert cfg[block][key] == (host[block][key] if explicit else expected)
    cfg["p2pool"]["pool"] = "nano"
    host_path.write_text(json.dumps({k: v for k, v in cfg.items() if not k.startswith("_")}))
    assert control_service.read_config()[block][key] == (host[block][key] if explicit else expected)


def test_unknown_platform_is_rejected():
    with pytest.raises(ValueError, match="unknown configuration platform"):
        effective_defaults("unknown")


@pytest.mark.parametrize("role,enabled", [("pithead", False), ("both", True)])
def test_no_javascript_role_is_an_explicit_miner_choice(role, enabled):
    assert build_config({"role": role})["local_miner"]["enabled"] is enabled


@pytest.mark.parametrize("platform", ["diy", "appliance"])
@pytest.mark.parametrize("explicit", [False, True])
async def test_sparse_browser_submit_materializes_defaults_without_replacing_answers(
    tmp_path, monkeypatch, platform, explicit
):
    from aiohttp.test_utils import TestClient, TestServer

    from mining_dashboard.wizard import server as wizard

    monkeypatch.setenv("WIZARD_SPOOL", str(tmp_path))
    monkeypatch.setenv("WIZARD_TOKEN", "fixture-token")
    tmp_path.joinpath("config.reference.json").write_text(
        json.dumps(effective_defaults(legacy=True))
    )
    tmp_path.joinpath("platform.txt").write_text(platform)
    payload = {"monero": {"wallet_address": "fixture-wallet"}}
    if explicit:
        payload.update({"local_miner": {"enabled": False}, "dashboard": {"host": "chosen"}})
    async with TestClient(TestServer(wizard.make_app(exit_fn=lambda code: None))) as client:
        await client.post("/auth", data={"token": "fixture-token"}, allow_redirects=False)
        response = await client.post("/submit", data={"config": json.dumps(payload)})
        assert response.status == 200
    written = json.loads(tmp_path.joinpath("config.json").read_text())
    for path in TABLE["materialize"]:
        block, key = path.split(".")
        expected = default_of(path, platform)
        if explicit and key in payload.get(block, {}):
            expected = payload[block][key]
        assert written[block][key] == expected
