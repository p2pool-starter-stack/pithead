"""New-install answers are separate from the reference used by existing configs."""

import json

import pytest
from aiohttp.test_utils import TestClient, TestServer

from mining_dashboard.wizard import server as wizard

# The host's published reference, trimmed to what these read. `tari.mode` is "local" here because
# that is what config.reference.json says: a config that omits the key means local, which is what
# keeps a 1.x install merge-mining across the 2.0 upgrade.
REFERENCE = {
    "monero": {"wallet_address": "", "mode": "local", "prune": True},
    "tari": {"wallet_address": "", "mode": "local"},
    "p2pool": {"pool": "mini"},
    "xvb": {"enabled": True},
}


@pytest.fixture
def spool(tmp_path, monkeypatch):
    sd = tmp_path / "spool"
    sd.mkdir()
    monkeypatch.setenv("WIZARD_SPOOL", str(sd))
    monkeypatch.setenv("WIZARD_TOKEN", "pit-X7KM2Q")
    sd.joinpath("config.reference.json").write_text(json.dumps(REFERENCE))
    return sd


@pytest.fixture
async def client(spool):
    c = TestClient(TestServer(wizard.make_app(exit_fn=lambda code: None)))
    await c.start_server()
    yield c
    await c.close()


async def _auth(client, token="pit-X7KM2Q"):  # noqa: S107 — the test fixture's token, not a secret
    return await client.post("/auth", data={"token": token}, allow_redirects=False)


async def _state(client):
    await _auth(client)
    return await (await client.get("/api/wizard-state")).json()


async def test_a_new_machine_uses_the_disk_rule_without_changing_reference(client, spool):
    """The finding: a fresh install showed Tari coming up for an operator who never asked."""
    spool.joinpath("disk-budget.json").write_text(
        json.dumps({"available_bytes": 10, "local_need_bytes": 528})
    )
    s = await _state(client)
    assert s["config"]["tari"]["mode"] == "off"
    spool.joinpath("disk-budget.json").write_text(
        json.dumps({"available_bytes": 528, "local_need_bytes": 528})
    )
    assert (await _state(client))["config"]["tari"]["mode"] == "local"
    # The reference the same response carries is untouched, and that is not incidental: the page
    # diffs against it to decide what to write, and the host reads a missing key as "local". If
    # this ever came back "off", `strip_defaults` would drop the decline as a no-op default and
    # the machine would merge-mine anyway.
    assert s["reference"]["tari"]["mode"] == "local"


async def test_the_page_default_does_not_reach_a_machine_that_already_answered(client, spool):
    """The migration guard, at the seam where it actually acts."""
    for attempt, expected in (
        # An install that chose local keeps local — the obvious half.
        ({"tari": {"mode": "local"}}, "local"),
        # The half that matters: a 1.x config predates the question entirely. It is still a
        # machine WITH answers, so it falls through to the reference's "local" and is never
        # handed the new machine's decline. Serving "off" here would tell an upgraded install it
        # had declined merge-mining, and submitting that page would write the decline back.
        ({"monero": {"wallet_address": "4AAA"}}, "local"),
    ):
        spool.joinpath("last-attempt.json").write_text(json.dumps(attempt))
        assert (await _state(client))["config"]["tari"]["mode"] == expected, attempt


async def test_a_rejected_attempt_keeps_the_decline_the_operator_just_made(client, spool):
    # The same path carries a submission the host bounced. An operator who answered No, hit a
    # validation error on some other field, and got the form back must not find Tari switched
    # back on underneath the error.
    spool.joinpath("last-attempt.json").write_text(json.dumps({"tari": {"mode": "off"}}))
    assert (await _state(client))["config"]["tari"]["mode"] == "off"


async def test_new_machine_raffle_is_off_but_existing_absence_keeps_reference(client, spool):
    assert (await _state(client))["config"]["xvb"]["enabled"] is False
    spool.joinpath("last-attempt.json").write_text(
        json.dumps({"monero": {"wallet_address": "4OLD"}})
    )
    assert (await _state(client))["config"]["xvb"]["enabled"] is True
