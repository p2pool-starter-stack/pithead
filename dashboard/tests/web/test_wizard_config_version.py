# ruff: noqa: F401, F811
import json

from mining_dashboard.wizard import server as wizard

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
