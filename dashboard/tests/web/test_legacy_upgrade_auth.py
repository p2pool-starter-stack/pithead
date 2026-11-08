import base64
import hashlib
import json
import secrets
import shutil
import subprocess
from pathlib import Path

import bcrypt

from mining_dashboard.web import server

ROOT = Path(__file__).resolve().parents[3]


def render_v2_auth(tmp_path, password):
    bash = shutil.which("bash")
    assert bash is not None
    fixture = ROOT / "tests/stack/fixtures/config-2.0.0"
    work = tmp_path / "legacy-install"
    work.mkdir()
    config = json.loads((fixture / "absent.json").read_text())
    config["dashboard"]["auth"] = {"username": "admin", "password": password}
    (work / "config.json").write_text(json.dumps(config))
    shutil.copy(ROOT / "VERSION", work / "VERSION")

    password_hash = bcrypt.hashpw(password.encode(), bcrypt.gensalt(rounds=4)).decode()
    password_fingerprint = hashlib.sha256(password.encode()).hexdigest()
    env = (fixture / "appliance.env").read_text()
    replacements = {
        "DASHBOARD_AUTH_HASH_B64": base64.b64encode(password_hash.encode()).decode(),
        "DASHBOARD_AUTH_PW_FP": password_fingerprint,
    }
    for key, value in replacements.items():
        env = "\n".join(
            f"{key}={value}" if line.startswith(f"{key}=") else line for line in env.splitlines()
        )
    (work / ".env").write_text(env + "\n")

    subprocess.run(  # noqa: S603 -- fixed test command with repository-owned inputs
        [
            bash,
            "-Eeuo",
            "pipefail",
            "-c",
            """
PITHEAD_BUILD_ARTIFACT="$PWD/pithead" "$BASH" "$1/scripts/build-pithead.sh"
source "$PWD/pithead"
PITHEAD_TEST_NODE="fixture-${RANDOM}-${RANDOM}"
hostname() { printf %s "$PITHEAD_TEST_NODE"; }
nproc() { printf 8; }
chown() { return 0; }
detect_host_timezone() { printf UTC; }
MONERO_ONION="${PITHEAD_TEST_NODE}.onion"
TARI_ONION="$MONERO_ONION" P2POOL_ONION="$MONERO_ONION"
DASHBOARD_ONION="" DASHBOARD_ONION_CLIENT_PUBKEY="" DASHBOARD_ONION_CLIENT_PRIVKEY=""
PROXY_AUTH_TOKEN="${RANDOM}${RANDOM}"
TARI_WALLET_PASSWORD="" WALLET_RPC_PASSWORD=""
PITHEAD_APPLIANCE=1
parse_and_validate_config
render_dashboard_auth "$PWD/control"
""",
            "_",
            str(ROOT),
        ],
        cwd=work,
        check=True,
    )
    return work / "control/auth/auth.json", password_hash


async def test_v2_config_legacy_password_logs_in_after_auth_render(
    tmp_path, monkeypatch, state_manager, aiohttp_client
):
    password = secrets.token_urlsafe(18)
    auth_path, password_hash = render_v2_auth(tmp_path, password)
    rendered = json.loads(auth_path.read_text())
    assert [(user["name"], user["role"]) for user in rendered["users"]] == [("admin", "admin")]
    assert rendered["users"][0]["password_hash"] == password_hash

    monkeypatch.setenv("DASHBOARD_AUTH_FILE", str(auth_path))
    monkeypatch.setattr(server.config, "DASHBOARD_CONTROL_ENABLED", True)
    client = await aiohttp_client(server.create_app(state_manager, {}))
    origin = str(client.make_url("/").origin())
    response = await client.post(
        "/login",
        data={"username": "admin", "password": password},
        headers={"Origin": origin},
        allow_redirects=False,
    )
    assert response.status == 303
    assert await (await client.get("/api/auth/session")).json() == {
        "enabled": True,
        "user": "admin",
        "role": "admin",
    }
