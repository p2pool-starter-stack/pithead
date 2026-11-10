# ruff: noqa: F401, F811
import json
from pathlib import Path

import pytest

from mining_dashboard.config.defaults import effective_defaults
from mining_dashboard.wizard import server as wizard
from mining_dashboard.wizard_config import prepare_config

from ._wizard_support import _auth, client, seeded, spool  # noqa: F401


async def test_wizard_never_shows_or_submits_host_stamp(client, seeded):
    reference = json.loads(seeded.joinpath("config.reference.json").read_text())
    reference["config_version"] = "2.0.0"
    seeded.joinpath("config.reference.json").write_text(json.dumps(reference))
    cfg = {
        "config_version": "9.9.9",
        "monero": {"wallet_address": "test-wallet"},
        "tari": {"mode": "off"},
    }
    seeded.joinpath("last-attempt.json").write_text(json.dumps(cfg))
    assert "config_version" not in wizard._reference()
    await _auth(client)
    state = await (await client.get("/api/wizard-state")).json()
    assert "config_version" not in state["reference"]
    assert "config_version" not in state["config"]
    response = await client.post("/submit", data={"config": json.dumps(cfg)})
    assert response.status == 200
    assert "config_version" not in json.loads(seeded.joinpath("config.json").read_text())
    assert "config_version" not in seeded.joinpath("last-attempt.json").read_text()


FIXTURES = Path(__file__).resolve().parents[1] / "fixtures/config-2.0.0"
INPUTS = sorted((FIXTURES / "inputs").glob("*.json"))


@pytest.mark.parametrize("platform", ["diy", "appliance"])
@pytest.mark.parametrize("path", INPUTS, ids=lambda path: path.stem)
def test_prepare_config_migrates_every_fixture_like_the_host(path, platform):
    migrated, changes = prepare_config(
        json.loads(path.read_text()), effective_defaults(), platform=platform
    )
    golden = FIXTURES / "migrated" / f"{path.stem}.{platform}.json"
    assert migrated == json.loads(golden.read_text())
    assert changes[0].startswith("profile → ")
    assert not any(secret in " ".join(changes) for secret in ("fixture-", "123456:TOKEN"))
