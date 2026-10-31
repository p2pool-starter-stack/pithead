"""Both appliance submission paths use explicit defaults and the target disk's budget."""

import json

import pytest
from aiohttp.test_utils import TestClient, TestServer

from mining_dashboard.wizard import server as wizard
from mining_dashboard.wizard.defaults import disk_inventory, tari_disk_default

GIB = 1024**3
BUDGET = {
    "available_bytes": 900 * GIB,
    "local_need_bytes": 528 * GIB,
    "remote_need_bytes": 208 * GIB,
}


@pytest.mark.parametrize("available", [100, 900])
def test_enter_means_off_however_much_disk_is_free(available):
    disks = [{"name": "target", "data_bytes": available * GIB}]
    assert tari_disk_default(BUDGET, disks, "target") == "off"
    assert tari_disk_default({**BUDGET, "available_bytes": available * GIB}, [], "") == "off"


def test_booted_data_disk_that_holds_a_tari_chain_keeps_local():
    assert tari_disk_default({**BUDGET, "tari_chain_held": True}, [], "") == "local"
    assert tari_disk_default({**BUDGET, "tari_chain_held": False}, [], "") == "off"
    assert tari_disk_default({}, [], "") == "off"


def test_inventory_retains_old_shape_and_unknown_capacity_defaults_off():
    disks = disk_inventory(
        "target\t600G\tmodel\tserial\tempty\t567000000000\nold\t100G\tm\ts\tempty"
    )
    assert disks[0]["data_bytes"] == 567000000000
    assert "data_bytes" not in disks[1]
    assert tari_disk_default({}, disks, "old") == "off"


@pytest.mark.parametrize("javascript", [False, True])
@pytest.mark.parametrize("held,mode", [(False, "off"), (True, "local")])
async def test_new_install_submission_pins_disk_answer_raffle_and_private_sync(
    tmp_path, monkeypatch, javascript, held, mode
):
    monkeypatch.setenv("WIZARD_SPOOL", str(tmp_path))
    monkeypatch.setenv("WIZARD_TOKEN", "fixture-token")
    reference = {
        "monero": {"mode": "local", "wallet_address": "", "clearnet_initial_sync": False},
        "tari": {"mode": "local", "wallet_address": "", "clearnet_initial_sync": False},
        "xvb": {"enabled": True},
        "dashboard": {"host": "pithead", "tari_required": True},
        "p2pool": {"pool": "mini", "stratum_password": "auto"},
    }
    tmp_path.joinpath("config.reference.json").write_text(json.dumps(reference))
    tmp_path.joinpath("disk-budget.json").write_text(
        json.dumps({**BUDGET, "tari_chain_held": held})
    )
    async with TestClient(TestServer(wizard.make_app(exit_fn=lambda code: None))) as client:
        await client.post("/auth", data={"token": "fixture-token"}, allow_redirects=False)
        state = await (await client.get("/api/wizard-state")).json()
        assert state["config"]["tari"]["mode"] == mode
        cfg = state["config"]
        cfg["monero"]["wallet_address"] = "4FIXTURE"
        if mode == "local":
            cfg["tari"]["wallet_address"] = "tari-fixture"
        form = (
            {"config": json.dumps(cfg), "auth_mode": "auto"}
            if javascript
            else {"monero_wallet": "4FIXTURE", "tari_wallet": "tari-fixture"}
        )
        response = await client.post("/submit", data=form)
        assert response.status == 200
        written = json.loads(tmp_path.joinpath("config.json").read_text())
        assert written["tari"]["mode"] == mode
        # An opted-in beta Tari must not hold or reject Monero mining (#3333).
        if mode == "local":
            assert written["dashboard"]["tari_required"] is False
        else:
            assert "tari_required" not in written.get("dashboard", {})
        assert written["xvb"]["enabled"] is False
        assert written["monero"]["clearnet_initial_sync"] is False
        assert written["tari"]["clearnet_initial_sync"] is False


async def test_no_javascript_fast_sync_response_warns_for_both_local_networks(
    tmp_path, monkeypatch
):
    monkeypatch.setenv("WIZARD_SPOOL", str(tmp_path))
    monkeypatch.setenv("WIZARD_TOKEN", "fixture-token")
    async with TestClient(TestServer(wizard.make_app(exit_fn=lambda code: None))) as client:
        await client.post("/auth", data={"token": "fixture-token"}, allow_redirects=False)
        response = await client.post(
            "/submit",
            data={
                "monero_wallet": "4FIXTURE",
                "tari_mode": "local",
                "tari_wallet": "tari-fixture",
                "clearnet_sync": "true",
            },
        )
        assert (
            (await response.json())["warning"]
            == "Fast sync exposes your IP address to the Monero network and the Tari network until the initial sync finishes."
        )


@pytest.mark.parametrize("block", ["monero", "tari", "xvb"])
@pytest.mark.parametrize("invalid", [None, 1, "invalid", []])
async def test_wrong_known_section_types_are_spooled_for_host_rejection_without_a_500(
    tmp_path, monkeypatch, block, invalid
):
    monkeypatch.setenv("WIZARD_SPOOL", str(tmp_path))
    monkeypatch.setenv("WIZARD_TOKEN", "fixture-token")
    reference = {"monero": {"mode": "local"}, "tari": {"mode": "local"}, "xvb": {"enabled": True}}
    tmp_path.joinpath("config.reference.json").write_text(json.dumps(reference))
    async with TestClient(TestServer(wizard.make_app(exit_fn=lambda code: None))) as client:
        await client.post("/auth", data={"token": "fixture-token"}, allow_redirects=False)
        response = await client.post("/submit", data={"config": json.dumps({block: invalid})})
        assert response.status == 200
        assert json.loads(tmp_path.joinpath("config.json").read_text())[block] == invalid
        assert tmp_path.joinpath("submission-active").exists()
        assert (await response.json())["warning"] == ""


def test_only_the_data_wipe_option_keeps_the_chains_of_an_existing_install():
    disks = disk_inventory(f"target\t1T\tm\ts\tpithead-with-data\t{900 * GIB}\t{100 * GIB}")
    assert tari_disk_default(BUDGET, disks, "target", "data") == "local"
    assert tari_disk_default(BUDGET, disks, "target", "all") == "off"
    blank = disk_inventory(f"target\t1T\tm\ts\tempty\t{900 * GIB}")
    assert tari_disk_default(BUDGET, blank, "target", "data") == "off"
