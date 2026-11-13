# ruff: noqa: F403, F405
from mining_dashboard.config.defaults import effective_defaults
from tests.web._wizard_support import *  # noqa: F403


@pytest.mark.parametrize("auth_mode", ["none", "whatever", "set", "auto"])
async def test_legacy_auth_choice_cannot_disable_generated_login(client, seeded, auth_mode):
    seeded.joinpath("config.reference.json").write_text(json.dumps(effective_defaults(legacy=True)))
    await _auth(client)
    cfg = {"monero": {"wallet_address": "4XYZ"}, "tari": {"wallet_address": "t"}}
    response = await client.post(
        "/submit", data={"config": json.dumps(cfg), "auth_mode": auth_mode}
    )
    assert response.status == 200
    assert (seeded / "auth-mode").read_text() == "auto"
    assert "auth" not in json.loads((seeded / "config.json").read_text()).get("dashboard", {})
    assert "password" not in await response.text()


async def test_advanced_explicit_empty_password_selects_no_login(client, seeded):
    seeded.joinpath("config.reference.json").write_text(json.dumps(effective_defaults(legacy=True)))
    await _auth(client)
    cfg = {
        "monero": {"wallet_address": "4XYZ"},
        "tari": {"wallet_address": "t"},
        "dashboard": {"auth": {"username": "admin", "password": ""}},
    }
    response = await client.post("/submit", data={"config": json.dumps(cfg)})
    assert response.status == 200
    assert (seeded / "auth-mode").read_text() == "none"
    assert json.loads((seeded / "config.json").read_text())["dashboard"]["auth"]["password"] == ""


async def test_browser_enter_through_keeps_automatic_login(client, seeded):
    seeded.joinpath("config.reference.json").write_text(json.dumps(effective_defaults(legacy=True)))
    await _auth(client)
    state = await (await client.get("/api/wizard-state")).json()
    cfg = state["config"]
    assert cfg["dashboard"]["auth"] == {"username": "admin", "password": None}
    cfg["monero"]["wallet_address"] = "4XYZ"
    cfg["tari"]["wallet_address"] = "t"
    response = await client.post("/submit", data={"config": json.dumps(cfg), "auth_mode": "auto"})
    assert response.status == 200
    assert (seeded / "auth-mode").read_text() == "auto"
    assert json.loads((seeded / "config.json").read_text())["dashboard"]["auth"]["password"] is None


async def test_form_enter_through_keeps_automatic_login(client, seeded):
    seeded.joinpath("config.reference.json").write_text(json.dumps(effective_defaults(legacy=True)))
    await _auth(client)
    response = await client.post("/submit", data={"monero_wallet": "4XYZ", "tari_wallet": "t"})
    assert response.status == 200
    assert (seeded / "auth-mode").read_text() == "auto"
    assert json.loads((seeded / "config.json").read_text())["dashboard"]["auth"]["password"] is None
