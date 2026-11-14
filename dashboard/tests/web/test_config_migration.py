import json
from pathlib import Path

import pytest

from mining_dashboard.config.defaults import TABLE, effective_defaults
from mining_dashboard.wizard_config import prepare_config

FIXTURES = Path(__file__).resolve().parents[1] / "fixtures/config-2.0.0"
REFERENCE = effective_defaults()
INPUTS = sorted((FIXTURES / "inputs").glob("*.json"))
TIERS = TABLE["tiers"]


def leaves(node, prefix=""):
    for key, value in node.items():
        path = f"{prefix}.{key}" if prefix else key
        if key.startswith("_") or path == "config_version":
            continue
        if isinstance(value, dict) and value:
            yield from leaves(value, path)
        else:
            yield path


def tiers_of(leaf):
    names = [
        name
        for name, paths in TIERS.items()
        if any(leaf == path or leaf.startswith(path + ".") for path in paths)
    ]
    if leaf in TABLE["profiles"]["balance"]:
        names.append("profile")
    return names


def test_prepare_config_without_a_platform_never_migrates():
    cfg = json.loads((FIXTURES / "inputs/diy-login.json").read_text())
    assert prepare_config(cfg, REFERENCE)[0] == cfg


@pytest.mark.parametrize(
    "extra",
    [{"config_version": "2.1.0"}, {"config_version": "9.9.9"}, {"profile": "privacy"}],
)
def test_migration_skips_current_and_profiled_configs(extra):
    cfg = {**json.loads((FIXTURES / "inputs/diy-login.json").read_text()), **extra}
    migrated, changes = prepare_config(cfg, REFERENCE, platform="diy")
    assert migrated == {k: v for k, v in cfg.items() if k != "config_version"}
    assert changes == []


@pytest.mark.parametrize("stamp", ["old", 17, None, "100000.1.0"])
def test_malformed_stamp_migrates_as_2_0_0(stamp):
    cfg = {"config_version": stamp, "monero": {"wallet_address": "w"}}
    assert prepare_config(cfg, REFERENCE, platform="diy")[0]["profile"] == "balance"


def test_partly_performance_shaped_config_stays_balance():
    cfg = {
        "monero": {"clearnet_initial_sync": True},
        "tari": {"clearnet_initial_sync": True},
        "network": {"tor_egress_firewall": False},
    }
    assert prepare_config(cfg, REFERENCE, platform="diy")[0]["profile"] == "balance"


def test_mixed_config_migrates_to_balance_and_keeps_its_override():
    cfg = {"p2pool": {"clearnet": True}, "tor": {"auto_heal": True}}
    migrated, _ = prepare_config(cfg, REFERENCE, platform="diy")
    assert migrated["profile"] == "balance"
    assert migrated["p2pool"]["clearnet"] is True


def test_every_reference_leaf_has_one_tier_and_every_tier_path_exists():
    found = list(leaves(REFERENCE))
    assert {"profile", "workers.list", "telegram.events.node_down"} <= set(found)
    for leaf in found:
        assert len(tiers_of(leaf)) <= 1, (leaf, tiers_of(leaf))
    for name, paths in TIERS.items():
        for path in paths:
            assert any(leaf == path or leaf.startswith(path + ".") for leaf in found), (name, path)


def test_essentials_stay_within_the_cap():
    assert len(TIERS["essential"]) <= 15


@pytest.mark.parametrize("stamped", [True, False])
async def test_wizard_submit_migrates_only_a_stamped_2_0_0_config(tmp_path, monkeypatch, stamped):
    from aiohttp.test_utils import TestClient, TestServer

    from mining_dashboard.wizard import server as wizard

    monkeypatch.setenv("WIZARD_SPOOL", str(tmp_path))
    monkeypatch.setenv("WIZARD_TOKEN", "fixture-token")
    tmp_path.joinpath("config.reference.json").write_text(json.dumps(effective_defaults()))
    tmp_path.joinpath("platform.txt").write_text("diy")
    payload = {"monero": {"wallet_address": "fixture-wallet"}}
    if stamped:
        payload["config_version"] = "2.0.0"
    async with TestClient(TestServer(wizard.make_app())) as client:
        await client.post("/auth", data={"token": "fixture-token"}, allow_redirects=False)
        response = await client.post("/submit", data={"config": json.dumps(payload)})
        assert response.status == 200
    written = json.loads(tmp_path.joinpath("config.json").read_text())
    assert written["tari"]["mode"] == ("local" if stamped else "off")
