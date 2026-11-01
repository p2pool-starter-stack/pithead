import json
import os
import subprocess
import sys
from pathlib import Path

import pytest

# ruff: noqa: S101, S603

ROOT = Path(__file__).resolve().parents[2]


def _run(script, implementation="python"):
    env = os.environ.copy()
    env.update(
        PITHEAD_IMPL=implementation,
        PITHEAD_DASHBOARD_GO_BINARY=str(ROOT / "go/bin/dashboard"),
        PYTHONPATH=str(ROOT / "dashboard"),
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


def _paired(script):
    expected = _run(script)
    actual = _run(script, "go")
    assert actual == expected
    return actual


def test_auth_canonical_cookie_and_http_policy_match():
    result = _paired(
        r"""
import asyncio, json, os
from types import SimpleNamespace
from aiohttp.test_utils import TestClient, TestServer
from mining_dashboard.wizard import server
if os.environ["PITHEAD_IMPL"] == "go":
    from mining_dashboard.go_wizard_policy import install
    install(server)
os.environ["WIZARD_TOKEN"] = "pit-X7KM2Q"
canonical = [server._canon_token(value) for value in (
    " pit-x7km2q ", "pit-Stra\u00dfe", "\u3000pit-\ufb03\u00a0"
)]
cookies = []
for token, cookie in (("", "\u00df"), ("pit-X7KM2Q", "pit-X7KM2Q"),
                      ("pit-X7KM2Q", "PIT-X7KM2Q"), ("pit-\u00df", "pit-\u00df")):
    os.environ["WIZARD_TOKEN"] = token
    try:
        cookies.append(["value", server._authed(SimpleNamespace(cookies={server.COOKIE: cookie}))])
    except Exception as error:
        cookies.append([type(error).__name__, str(error)])
os.environ["WIZARD_TOKEN"] = "pit-X7KM2Q"
async def run():
    exits = []
    app = server.make_app(exit_fn=exits.append)
    async with TestClient(TestServer(app)) as client:
        statuses = []
        for _ in range(server.MAX_FAILURES):
            response = await client.post("/auth", data={"token": "wrong"}, allow_redirects=False)
            statuses.append(response.status)
        lockout = await response.json()
    app = server.make_app(exit_fn=exits.append)
    async with TestClient(TestServer(app)) as client:
        response = await client.post(
            "/auth", data={"token": "  x7km2q  "}, allow_redirects=False
        )
        cookie = response.headers.get("Set-Cookie", "")
        accepted = [response.status, "HttpOnly" in cookie, "SameSite=Strict" in cookie]
    return {"statuses": statuses, "lockout": lockout, "exits": exits, "accepted": accepted}
print(json.dumps({"canonical": canonical, "cookies": cookies, "http": asyncio.run(run())}))
"""
    )
    assert result["canonical"] == ["X7KM2Q", "STRASSE", "FFI"]
    assert result["cookies"][-1][0] == "TypeError"
    assert result["http"]["statuses"] == [403, 403, 403, 403, 429]


@pytest.mark.parametrize("platform", ["diy", "appliance"])
def test_form_json_bytes_and_native_password_policy_match(platform):
    result = _paired(
        rf"""
import json, os
from mining_dashboard.wizard import form
from mining_dashboard.wizard import server
if os.environ["PITHEAD_IMPL"] == "go":
    from mining_dashboard.go_wizard_policy import install
    install(server)
forms = [
    {{}},
    {{"machine_name":" chosen ","monero_wallet":"wallet","monero_mode":"remote",
      "monero_remote_host":"node.example.com","monero_remote_rpc":"18081",
      "monero_remote_zmq":"not-a-port","monero_remote_auth":"on",
      "monero_remote_user":" reader ","monero_remote_pass":" pass ",
      "pool":"nano","tari_mode":"remote","tari_wallet":"tari",
      "tari_remote_host":"tari.example.com","tari_remote_grpc":"18142",
      "healthchecks_url":" https://hc.example.com/ping ",
      "telegram_token":" token ","telegram_chat":" chat ","role":"pithead",
      "local_miner":"true","clearnet_sync":"true","timezone":"Europe/Berlin"}},
    {{"monero_mode":"local","prune":"false","tari_mode":"off",
      "local_miner":"0","clearnet_sync":"false"}},
    {{"stratum_password":"true"}},
]
values = []
for item in forms:
    config = form.build_config(item, platform={platform!r})
    password = config["p2pool"]["stratum_password"]
    if item.get("stratum_password") == "true":
        config["p2pool"]["stratum_password"] = "<hex24>" if (
            len(password) == 24 and all(char in "0123456789abcdef" for char in password)
        ) else "<invalid>"
    values.append(json.dumps(config, separators=(",", ":")))
print(json.dumps(values))
"""
    )
    assert result[-1].count("<hex24>") == 1


def test_install_validation_results_and_failures_match():
    result = _paired(
        r"""
import json, os
from mining_dashboard import wizard_install
from mining_dashboard.wizard import server
if os.environ["PITHEAD_IMPL"] == "go":
    from mining_dashboard.go_wizard_policy import install
    install(server)
disks = [
    {"name":"disk-empty","state":"empty"},
    {"name":"disk-data","state":"pithead-with-data"},
]
cases = [
    {"disk":"disk-empty","confirm":"disk-empty"},
    {"disk":"disk-empty","confirm":"disk-empty","wipe":"all"},
    {"disk":"disk-data","confirm":"disk-data","wipe":"data"},
    {"disk":"missing","confirm":"missing"},
    {"disk":"disk-data","confirm":"wrong"},
    {"disk":"disk-data","confirm":"disk-data","wipe":"invented"},
]
values = []
for item in cases:
    try:
        values.append(["value", wizard_install.validate_install_request(item, disks)])
    except Exception as error:
        values.append([type(error).__name__, str(error)])
print(json.dumps(values))
"""
    )
    assert result[:3] == [
        ["value", {"disk": "disk-empty", "wipe": "keep"}],
        ["value", {"disk": "disk-empty", "wipe": "keep"}],
        ["value", {"disk": "disk-data", "wipe": "data"}],
    ]
    assert all(item[0] == "ValueError" for item in result[3:])
