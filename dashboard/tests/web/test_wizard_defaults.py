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


@pytest.mark.parametrize(
    "monero,available,expected",
    [
        ("local", 527, "off"),
        ("local", 528, "local"),
        ("remote", 207, "off"),
        ("remote", 208, "local"),
    ],
)
def test_target_data_partition_decides_instead_of_boot_medium(monero, available, expected):
    disks = [{"name": "target", "data_bytes": available * GIB}]
    assert tari_disk_default(BUDGET, disks, "target", monero) == expected
    assert (
        tari_disk_default({**BUDGET, "available_bytes": available * GIB}, [], "", monero)
        == expected
    )


def test_unknown_capacity_matches_cli_local_fallback_and_inventory_retains_old_shape():
    disks = disk_inventory(
        "target\t600G\tmodel\tserial\tempty\t567000000000\nold\t100G\tm\ts\tempty"
    )
    assert disks[0]["data_bytes"] == 567000000000
    assert "data_bytes" not in disks[1]
    assert tari_disk_default({}, disks, "old", "local") == "local"


@pytest.mark.parametrize("javascript", [False, True])
@pytest.mark.parametrize("available,mode", [(100, "off"), (600, "local")])
async def test_new_install_submission_pins_disk_answer_raffle_and_private_sync(
    tmp_path, monkeypatch, javascript, available, mode
):
    monkeypatch.setenv("WIZARD_SPOOL", str(tmp_path))
    monkeypatch.setenv("WIZARD_TOKEN", "fixture-token")
    reference = {
        "monero": {"mode": "local", "wallet_address": "", "clearnet_initial_sync": False},
        "tari": {"mode": "local", "wallet_address": "", "clearnet_initial_sync": False},
        "xvb": {"enabled": True},
        "dashboard": {"host": "pithead"},
        "p2pool": {"pool": "mini", "stratum_password": "auto"},
    }
    tmp_path.joinpath("config.reference.json").write_text(json.dumps(reference))
    tmp_path.joinpath("disk-budget.json").write_text(
        json.dumps({**BUDGET, "available_bytes": available * GIB})
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
                "tari_wallet": "tari-fixture",
                "clearnet_sync": "true",
            },
        )
        assert (
            (await response.json())["warning"]
            == "Fast sync exposes your IP address to the Monero network and the Tari network until the initial sync finishes."
        )
