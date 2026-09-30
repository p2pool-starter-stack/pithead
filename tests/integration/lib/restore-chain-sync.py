"""Read-only daemon sync proof using the restored credentials and direct Tari gRPC."""

import hashlib
import http.client
import json
import secrets
import shutil
import subprocess
import time
from pathlib import Path
from urllib.parse import urlsplit
from urllib.request import parse_http_list, parse_keqv_list

TARI_PROBE = """
import json, os, grpc
from google.protobuf import empty_pb2
from mining_dashboard.client.tari.generated import base_node_pb2_grpc
with grpc.insecure_channel(os.environ['TARI_GRPC_ADDRESS']) as channel:
    tip = base_node_pb2_grpc.BaseNodeStub(channel).GetTipInfo(empty_pb2.Empty(), timeout=8)
print(json.dumps({'initial_sync_achieved': tip.initial_sync_achieved}))
"""


STAGE = "environment"


def digest_header(challenges, user, password, path):
    # Monero advertises MD5 and MD5-sess separately. Select its MD5/auth challenge.
    for value in challenges:
        scheme, _, fields = value.partition(" ")
        if scheme.lower() != "digest":
            continue
        challenge = parse_keqv_list(parse_http_list(fields))
        if challenge.get("algorithm", "MD5").upper() == "MD5" and "auth" in (
            part.strip() for part in challenge.get("qop", "").split(",")
        ):
            break
    else:
        raise ValueError("required Digest challenge missing")
    realm, nonce = challenge["realm"], challenge["nonce"]
    if not realm or not nonce:
        raise ValueError("incomplete Digest challenge")

    def quoted(value):
        if any(ord(char) < 32 or ord(char) == 127 for char in value):
            raise ValueError("invalid Digest field")
        return '"' + value.replace("\\", "\\\\").replace('"', '\\"') + '"'

    def md5(value):
        return hashlib.md5(value.encode(), usedforsecurity=False).hexdigest()

    cnonce = secrets.token_hex(16)
    response = md5(
        f"{md5(f'{user}:{realm}:{password}')}:{nonce}:00000001:{cnonce}:auth:{md5('GET:' + path)}"
    )
    fields = dict(
        username=user, realm=realm, nonce=nonce, uri=path, response=response, cnonce=cnonce
    )
    if "opaque" in challenge:
        fields["opaque"] = challenge["opaque"]
    return (
        "Digest "
        + ", ".join(key + "=" + quoted(value) for key, value in fields.items())
        + ", algorithm=MD5, qop=auth, nc=00000001"
    )


def monero_info(url, user, password):
    target = urlsplit(url)
    if (
        target.scheme not in ("http", "https")
        or not target.hostname
        or target.username is not None
        or target.password is not None
        or target.query
        or target.fragment
    ):
        raise ValueError("invalid daemon endpoint")
    path = target.path.rstrip("/") + "/get_info"
    transport = (
        http.client.HTTPSConnection if target.scheme == "https" else http.client.HTTPConnection
    )
    connection = transport(target.hostname, target.port, timeout=8)
    deadline = time.monotonic() + 8

    def read(response):
        payload = response.read(65537)
        if len(payload) > 65536:
            raise ValueError("daemon response too large")
        return payload

    try:
        # HTTPConnection connects directly; no proxy discovery or redirect handling.
        connection.request("GET", path)
        challenge = connection.getresponse()
        if challenge.status != 401 or challenge.will_close:
            raise ValueError("required persistent Digest session missing")
        headers = [
            value for key, value in challenge.getheaders() if key.lower() == "www-authenticate"
        ]
        read(challenge)
        authorization = digest_header(headers, user, password, path)
        remaining = deadline - time.monotonic()
        if remaining <= 0 or connection.sock is None:
            raise TimeoutError("Digest session expired")
        # Preserve the challenged socket. Never reconnect to retry credentials.
        connection.sock.settimeout(remaining)
        connection.request("GET", path, headers={"Authorization": authorization})
        response = connection.getresponse()
        if response.status != 200:
            raise ValueError("authenticated daemon request refused")
        return json.loads(read(response))
    finally:
        connection.close()


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
