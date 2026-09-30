"""Read-only daemon sync proof using the restored credentials and direct Tari gRPC."""

import json
import shutil
import subprocess
from pathlib import Path

TARI_PROBE = """
import json, os, grpc
from google.protobuf import empty_pb2
from mining_dashboard.client.tari.generated import base_node_pb2_grpc
with grpc.insecure_channel(os.environ['TARI_GRPC_ADDRESS']) as channel:
    tip = base_node_pb2_grpc.BaseNodeStub(channel).GetTipInfo(empty_pb2.Empty(), timeout=8)
print(json.dumps({'initial_sync_achieved': tip.initial_sync_achieved}))
"""


STAGE = "environment"


def probe(env_path=Path(".env")):
    global STAGE
    STAGE = "environment"
    env = dict(
        line.split("=", 1)
        for line in env_path.read_text().splitlines()
        if "=" in line and not line.startswith("#")
    )
    # Decode the double-quoted subset emitted by dotenv_render_value; never source .env.
    env = {
        key: json.loads(value).replace("$$", "$") if value.startswith('"') else value
        for key, value in env.items()
    }
    user, password = env.get("MONERO_NODE_USERNAME"), env.get("MONERO_NODE_PASSWORD")
    if not user or not password:
        return False
    url = env.get("MONERO_RPC_URL")
    if not url:
        return False
    STAGE = "monero-rpc"
    curl = shutil.which("curl")
    if not curl:
        return False
    # Match the existing host-side restoration auth transport. Feed credentials through
    # stdin, never argv, and capture all errors so only fixed stage verdicts leave the box.
    response = subprocess.run(  # noqa: S603
        [
            curl,
            "-q",
            "-fsS",
            "--max-filesize",
            "65536",
            "--max-time",
            "8",
            "--digest",
            "-K",
            "-",
            "--url",
            url.rstrip("/") + "/get_info",
        ],
        input="user = " + json.dumps(user + ":" + password, ensure_ascii=False) + "\n",
        capture_output=True,
        text=True,
        timeout=10,
        check=True,
    )
    monero = json.loads(response.stdout)
    STAGE = "monero-sync"
    if monero.get("status") != "OK" or monero.get("synchronized") is not True:
        return False
    STAGE = "tari-command"
    docker = shutil.which("docker")
    if not docker:
        return False
    # Fixed read-only command and checked-in probe, with no daemon response in argv.
    result = subprocess.run(  # noqa: S603
        [docker, "exec", "dashboard", "python3", "-c", TARI_PROBE],
        capture_output=True,
        text=True,
        timeout=12,
        check=True,
    )
    STAGE = "tari-sync"
    return json.loads(result.stdout).get("initial_sync_achieved") is True


if __name__ == "__main__":
    try:
        synced = probe()
    except Exception:
        # Exceptions can include private endpoints; only fixed verdicts leave the box.
        synced = False
    if synced:
        print("Monero authenticated synchronized=true; Tari direct initial_sync_achieved=true")
    else:
        print("independent daemon sync not proved: " + STAGE)
    raise SystemExit(0 if synced else 1)
