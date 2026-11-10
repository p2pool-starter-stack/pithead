import json
from pathlib import Path

import pytest

from mining_dashboard.config.defaults import TABLE
from mining_dashboard.wizard_config import prepare_config

ROOT = Path(__file__).resolve().parents[3]
FIXTURES = ROOT / "tests/stack/fixtures/config-2.0.0"
REFERENCE = json.loads((ROOT / "config.reference.json").read_text())
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


@pytest.mark.parametrize("platform", ["diy", "appliance"])
@pytest.mark.parametrize("path", INPUTS, ids=lambda path: path.stem)
def test_prepare_config_migrates_every_fixture_like_the_host(path, platform):
    migrated, changes = prepare_config(json.loads(path.read_text()), REFERENCE, platform=platform)
    assert migrated == json.loads(
        (FIXTURES / "migrated" / f"{path.stem}.{platform}.json").read_text()
    )
    assert changes[0].startswith("profile → ")
    assert not any(secret in " ".join(changes) for secret in ("fixture-", "123456:TOKEN"))


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


def test_tied_config_migrates_to_balance_and_keeps_its_override():
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


def test_essentials_stay_within_the_cap_and_feed_the_core_keys_file():
    assert len(TIERS["essential"]) <= 15
    assert json.loads((ROOT / "config.core-keys.json").read_text()) == TIERS["essential"]
