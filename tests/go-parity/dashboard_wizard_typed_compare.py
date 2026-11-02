import json
import os
import subprocess
import sys
from pathlib import Path

import pytest

# ruff: noqa: S101, S106, S603

ROOT = Path(__file__).resolve().parents[2]


def _run(script, directory, implementation="python"):
    env = os.environ.copy()
    env.update(
        PITHEAD_IMPL=implementation,
        PITHEAD_DASHBOARD_GO_BINARY=str(ROOT / "go/bin/dashboard"),
        PYTHONPYCACHEPREFIX=str(ROOT / ".go-cache/pycache"),
        PYTHONPATH=str(ROOT / "dashboard"),
        WIZARD_SPOOL=str(directory / "spool"),
        WIZARD_RESTORE=str(directory / "restore"),
        WIZARD_HANDOFF=str(directory / "handoff"),
        WIZARD_TOKEN="pit-fixture-token",
    )
    result = subprocess.run(
        [sys.executable, "-c", script],
        env=env,
        capture_output=True,
        text=True,
        timeout=40,
        check=False,
    )
    assert result.returncode == 0, result.stderr
    return json.loads(result.stdout.splitlines()[-1])


def _paired(tmp_path, script):
    expected = _run(script, tmp_path / "reference")
    actual = _run(script, tmp_path / "native", "go")
    assert actual == expected
    return actual


HTTP_PREAMBLE = r"""
import asyncio, json, os, stat
from pathlib import Path
from aiohttp.test_utils import TestClient, TestServer
from mining_dashboard.wizard import server
if os.environ["PITHEAD_IMPL"] == "go":
    from mining_dashboard import go_wizard_typed
    go_wizard_typed.install(server)
spool = Path(os.environ["WIZARD_SPOOL"])
spool.mkdir(parents=True)
Path(os.environ["WIZARD_RESTORE"]).mkdir(parents=True)
Path(os.environ["WIZARD_HANDOFF"]).mkdir(parents=True)
def tree():
    return {
        str(path.relative_to(spool)): [path.read_bytes().hex(), stat.S_IMODE(path.stat().st_mode)]
        for path in sorted(spool.rglob("*")) if path.is_file()
    }
async def submit(data):
    async with TestClient(TestServer(server.make_app(exit_fn=lambda code: None))) as client:
        await client.post("/auth", data={"token":"pit-fixture-token"}, allow_redirects=False)
        response = await client.post("/submit", data=data)
        return {"status":response.status, "body":(await response.read()).hex(), "spool":tree()}
"""


def test_raw_config_http_response_and_spool_bytes_match(tmp_path):
    result = _paired(
        tmp_path,
        HTTP_PREAMBLE
        + r"""
reference = {"monero":{"mode":"local","wallet_address":""},
             "dashboard":{"host":"auto"},"p2pool":{"pool":"mini"}}
spool.joinpath("config.reference.json").write_text(json.dumps(reference))
spool.joinpath("last-attempt.json").write_text(json.dumps(reference))
candidate = {"monero":{"mode":"local","wallet_address":"4FIXTURE"},
             "dashboard":{"host":"auto"},"p2pool":{"pool":"mini"}}
print(json.dumps(asyncio.run(submit({"config":json.dumps(candidate),"auth_mode":"set"})),
                 separators=(",",":")))
""",
    )
    assert result["status"] == 200
    assert "config.json" in result["spool"]
    assert result["spool"]["auth-mode"][0] == "736574"


def test_keep_preserves_disk_files_and_ignores_crafted_invalid_config(tmp_path):
    result = _paired(
        tmp_path,
        HTTP_PREAMBLE
        + r"""
spool.joinpath("disks.tsv").write_text("sda\t1T\tFixture\tSAFE123\tpithead-with-data\n")
print(json.dumps(asyncio.run(submit({"config":"not json","disk":"sda","confirm":"sda",
                                     "wipe":"keep","stratum_password":"true"})),
                 separators=(",",":")))
""",
    )
    assert result["status"] == 200
    assert "config.json" not in result["spool"]
    assert result["spool"]["install-request"][0] == "736461096b656570"


def test_failed_probe_response_and_retry_spool_match_without_network(tmp_path):
    result = _paired(
        tmp_path,
        HTTP_PREAMBLE
        + r"""
report = {"ok":False,"configured":1,"probed":1,"probes":[{
    "target":"monero","host":"node.example.com","port":18081,"ok":False,
    "checked":"rpc","reason":"auth","detail":"fixture probe rejected login","elapsed_ms":2}]}
async def failed(_cfg):
    return report
server.probe_remote_nodes = failed
reference = {"monero":{"mode":"remote","wallet_address":"","node_username":"",
             "node_password":"","remote":{"host":"","rpc_port":18081,"zmq_port":18083}}}
spool.joinpath("config.reference.json").write_text(json.dumps(reference))
spool.joinpath("last-attempt.json").write_text(json.dumps(reference))
candidate = {"monero":{"mode":"remote","wallet_address":"","node_username":"fixture",
             "node_password":"fixture-secret","remote":{"host":"node.example.com",
             "rpc_port":18081,"zmq_port":18083}}}
print(json.dumps(asyncio.run(submit({"config":json.dumps(candidate)})), separators=(",",":")))
""",
    )
    assert result["status"] == 400
    assert "node-probe.json" in result["spool"]
    assert "config.json" not in result["spool"]
    assert "install-request" not in result["spool"]


def test_optional_form_submission_matches_without_random_password(tmp_path):
    result = _paired(
        tmp_path,
        HTTP_PREAMBLE
        + r"""
spool.joinpath("platform.txt").write_text("diy")
print(json.dumps(asyncio.run(submit({"monero_wallet":"4FIXTURE","monero_mode":"local",
    "tari_mode":"off","pool":"mini","stratum_password":"false","auth_mode":"none"})),
    separators=(",",":")))
""",
    )
    assert result["status"] == 200
    config = json.loads(bytes.fromhex(result["spool"]["config.json"][0]))
    assert config["p2pool"]["stratum_password"] == ""


def test_missing_wipe_on_preserved_disk_still_submits_config(tmp_path):
    result = _paired(
        tmp_path,
        HTTP_PREAMBLE
        + r"""
spool.joinpath("disks.tsv").write_text("sda\t1T\tFixture\tSAFE123\tpithead-with-data\n")
print(json.dumps(asyncio.run(submit({"config":"{}","disk":"sda","confirm":"sda"})),
                 separators=(",",":")))
""",
    )
    assert result["status"] == 200
    assert "config.json" in result["spool"]
    assert result["spool"]["install-request"][0] == "736461096b656570"


def test_malformed_probe_keeps_its_report_before_returning_error(tmp_path):
    result = _paired(
        tmp_path,
        HTTP_PREAMBLE
        + r"""
async def malformed(_cfg):
    return {"configured":1}
server.probe_remote_nodes = malformed
print(json.dumps(asyncio.run(submit({"config":"{}"})), separators=(",",":")))
""",
    )
    assert result["status"] == 500
    assert "node-probe.json" in result["spool"]
    assert "config.json" not in result["spool"]


def test_unknown_json_key_keeps_lone_surrogate_in_change_messages(tmp_path):
    result = _paired(
        tmp_path,
        HTTP_PREAMBLE
        + r"""
reference = {"monero":{"wallet_address":"","mode":"local"},"dashboard":{"host":"auto"}}
spool.joinpath("config.reference.json").write_text(json.dumps(reference))
spool.joinpath("last-attempt.json").write_text(json.dumps(reference))
candidate = {**reference, "\ud800":1}
print(json.dumps(asyncio.run(submit({"config":json.dumps(candidate)})), separators=(",",":")))
""",
    )
    assert result["status"] == 200
    body = json.loads(bytes.fromhex(result["body"]))
    assert body["config_changes"] == ["\ud800 removed"]


@pytest.mark.parametrize("detail", ["None", r"'\ud800'", "float('nan')"])
def test_probe_error_detail_keeps_original_json_value(tmp_path, detail):
    result = _paired(
        tmp_path,
        HTTP_PREAMBLE
        + r"""
async def rejected(_cfg):
    return {"ok":False,"configured":1,"probes":[{"ok":False,"detail":DETAIL}]}
server.probe_remote_nodes = rejected
print(json.dumps(asyncio.run(submit({"config":"{}"})), separators=(",",":")))
""".replace("DETAIL", detail),
    )
    assert result["status"] == 400
    assert "node-probe.json" in result["spool"]
    assert "config.json" not in result["spool"]
