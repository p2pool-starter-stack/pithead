"""Read-only daemon sync proof using the restored credentials and direct Tari gRPC."""

import json
import shutil
import subprocess
from pathlib import Path
from tempfile import TemporaryDirectory
from urllib.parse import urlsplit

TARI_PROBE = """
import json, os, grpc
from google.protobuf import empty_pb2
from mining_dashboard.client.tari.generated import base_node_pb2_grpc
with grpc.insecure_channel(os.environ['TARI_GRPC_ADDRESS']) as channel:
    tip = base_node_pb2_grpc.BaseNodeStub(channel).GetTipInfo(empty_pb2.Empty(), timeout=8)
print(json.dumps({'initial_sync_achieved': tip.initial_sync_achieved}))
"""


STAGE = "environment"


def monero_info(url, user, password):
    target = urlsplit(url)
    if (
        target.scheme not in ("http", "https")
        or not target.hostname
        or target.username is not None
        or target.password is not None
        or target.query
        or target.fragment
        or any(ord(char) < 32 or ord(char) == 127 for char in user + password)
    ):
        raise ValueError("invalid daemon endpoint or credentials")
    curl = shutil.which("curl")
    if not curl:
        raise ValueError("required Digest transport unavailable")
    # libcurl owns Digest negotiation. Credentials go only to stdin; neither argv
    # nor the private response-header file contains the login. Disable ambient
    # curl configuration and proxies, redirects and non-HTTP protocols.
    with TemporaryDirectory(prefix="pithead-sync-") as scratch:
        headers = Path(scratch) / "headers"
        result = subprocess.run(  # noqa: S603
            [
                curl,
                "-q",
                "-fsS",
                "--http1.1",
                "--noproxy",
                "*",
                "--proto",
                "=http,https",
                "--no-location",
                "--max-filesize",
                "65536",
                "--max-time",
                "8",
                "--digest",
                "-K",
                "-",
                "--dump-header",
                str(headers),
                "--write-out",
                "\n%{num_connects} %{http_code} %{num_redirects}",
                "--url",
                url.rstrip("/") + "/get_info",
            ],
            input="user = " + json.dumps(user + ":" + password, ensure_ascii=False) + "\n",
            capture_output=True,
            text=True,
            timeout=10,
            check=True,
        )
        body, separator, counts = result.stdout.rpartition("\n")
        if not separator or counts != "1 200 0" or len(body.encode()) > 65536:
            raise ValueError("required authenticated connection not proved")
        with headers.open("rb") as stream:
            wire = stream.read(16385)
        if len(wire) > 16384:
            raise ValueError("daemon headers too large")
        blocks = wire.decode("iso-8859-1").strip().split("\r\n\r\n")
        if (
            len(blocks) != 2
            or blocks[0].split("\r\n", 1)[0].split()[1:2] != ["401"]
            or blocks[1].split("\r\n", 1)[0].split()[1:2] != ["200"]
            or not any(
                line.lower().startswith("www-authenticate: digest ")
                for line in blocks[0].split("\r\n")[1:]
            )
        ):
            raise ValueError("required Digest challenge not proved")
        return json.loads(body)


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
    monero = monero_info(url, user, password)
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
