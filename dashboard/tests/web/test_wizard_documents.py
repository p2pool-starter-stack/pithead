# ruff: noqa: F401, F811
"""Raw JSON refusal before the wizard normalizes or publishes a candidate."""

import json

import pytest

from ._wizard_support import _auth, client, seeded, spool


@pytest.mark.parametrize(
    ("raw", "diagnostic", "private_value"),
    [
        (
            '{"monero":{},"monero":{"password":"private-value"}}',
            'duplicate key "monero" at the top level (path monero)',
            "private-value",
        ),
        (
            '{"dashboard":{"auth":{"password":"first","password":"private-value"}}}',
            'duplicate key "password" at dashboard.auth (path dashboard.auth.password)',
            "private-value",
        ),
        (
            '{"dashboard":{"auth":{"password":"pAsTe_private-value"}}}',
            "placeholder value at dashboard.auth.password",
            "pAsTe_private-value",
        ),
        (
            '{"unknown":{"nested":["YoUr_private-value"]}}',
            "placeholder value at unknown.nested[0]",
            "YoUr_private-value",
        ),
    ],
)
async def test_submit_refuses_raw_document_without_publishing(
    client, seeded, raw, diagnostic, private_value
):
    await _auth(client)
    response = await client.post("/submit", data={"config": raw})
    assert response.status == 400
    body = await response.json()
    assert body == {"error": diagnostic}
    assert private_value not in json.dumps(body)
    for name in ("config.json", "last-attempt.json", "submission-active", "submission-staging"):
        assert not seeded.joinpath(name).exists()


async def test_submit_accepts_the_wizards_generated_document(client, seeded):
    await _auth(client)
    state = await (await client.get("/api/wizard-state")).json()
    response = await client.post("/submit", data={"config": json.dumps(state["config"])})
    assert response.status == 200
    assert (await response.json())["status"] == "accepted"
    assert seeded.joinpath("config.json").exists()
    attempted = json.loads(seeded.joinpath("last-attempt.json").read_text())
    assert attempted["monero"]["wallet_address"] == state["config"]["monero"]["wallet_address"]
    assert attempted["p2pool"]["pool"] == state["config"]["p2pool"]["pool"]
    assert seeded.joinpath("submission-active").exists()


@pytest.mark.parametrize("raw", ['{"password":"private-value",}', "null", "[]", "42"])
async def test_submit_returns_a_fixed_message_for_invalid_json(client, seeded, raw):
    await _auth(client)
    response = await client.post("/submit", data={"config": raw})
    assert response.status == 400
    assert await response.json() == {"error": "Not valid JSON: enter a JSON object."}
    assert not seeded.joinpath("config.json").exists()
