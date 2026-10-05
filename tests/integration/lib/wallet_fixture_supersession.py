"""Prove retained/live wallet identity without importing a superseded cache."""

import fcntl
import hashlib
import importlib.util
import json
import os
import re
import stat
import subprocess
import sys
import tarfile
import tempfile
from pathlib import Path

# RPC sees only an isolated tmpfs copy. The fixture file password is empty, as in
# build/monero/wallet-entrypoint.sh. No daemon, published port or live mount exists.
OPEN_COPY = r"""
set -eu
umask 077
tar -C /proof --no-same-owner -xf -
monero-wallet-rpc --offline --no-initial-sync --wallet-file /proof/payout-wallet \
    --password '' --disable-rpc-login --rpc-bind-ip 127.0.0.1 --rpc-bind-port 18082 \
    --shared-ringdb-dir /proof/ringdb --log-file /proof/wallet.log \
    --max-concurrency 1 --non-interactive >/dev/null 2>&1 &
pid=$!
trap 'kill -TERM "$pid" 2>/dev/null || true; wait "$pid"' EXIT
trap 'exit 1' TERM INT HUP
rpc() {
    curl --silent --fail --max-time 5 --max-filesize 8192 \
        -H 'Content-Type: application/json' -d "$1" http://127.0.0.1:18082/json_rpc
}
i=0
until rpc '{"jsonrpc":"2.0","id":"0","method":"get_address","params":{"account_index":0,"address_index":[0]}}' > /proof/address.json; do
    kill -0 "$pid" || exit 1
    i=$((i + 1)); [ "$i" -lt 120 ] || exit 1
    sleep 1
done
rpc '{"jsonrpc":"2.0","id":"0","method":"query_key","params":{"key_type":"view_key"}}' > /proof/key.json
jq -er '.result.address | select(type == "string" and test("^[1-9A-HJ-NP-Za-km-z]{95}$"))' /proof/address.json > /proof/address
jq -er '.result.key | select(type == "string" and test("^[0-9a-fA-F]{64}$")) | ascii_downcase' /proof/key.json > /proof/key
address=$(sha256sum /proof/address | cut -d ' ' -f 1)
view_key=$(sha256sum /proof/key | cut -d ' ' -f 1)
printf '{"address_fingerprint":"%s","view_key_fingerprint":"%s"}\n' "$address" "$view_key"
"""


def read_private(fixture, path, limit=16384):
    descriptor = os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
    with os.fdopen(descriptor, "rb") as stream:
        info = os.fstat(stream.fileno())
        fixture.private(info)
        if info.st_size > limit:
            raise ValueError("supersession evidence exceeds its limit")
        return stream.read(limit + 1)


def request_data(raw):
    def unique(pairs):
        result = {}
        for key, value in pairs:
            if key in result:
                raise ValueError("duplicate supersession request field")
            result[key] = value
        return result

    if len(raw) > 16384:
        raise ValueError("supersession request exceeds its limit")
    data = json.loads(raw, object_pairs_hook=unique)
    fields = {
        "schema",
        "original_job",
        "original_commit",
        "successor_job",
        "successor_commit",
        "recovery_issues",
    }
    if (
        not isinstance(data, dict)
        or set(data) != fields
        or type(data["schema"]) is not int
        or data["schema"] != 1
    ):
        raise ValueError("invalid supersession request schema")
    for key in ("original_job", "successor_job"):
        if type(data[key]) is not int or not 0 < data[key] < 2**63:
            raise ValueError("invalid supersession job reference")
    if data["original_job"] == data["successor_job"]:
        raise ValueError("successor must be a different job")
    for key in ("original_commit", "successor_commit"):
        if not isinstance(data[key], str) or not re.fullmatch(r"[0-9a-f]{40}", data[key]):
            raise ValueError("invalid supersession commit reference")
    refs = data["recovery_issues"]
    if (
        not isinstance(refs, list)
        or not 1 <= len(refs) <= 16
        or any(
            not isinstance(ref, str)
            or not re.fullmatch(r"(?:pithead|bench-ci)#[1-9][0-9]{0,9}", ref)
            for ref in refs
        )
        or len(set(refs)) != len(refs)
    ):
        raise ValueError("invalid supersession recovery references")
    return data


def open_copy(fixture, image, archive, directory, suffix):
    name = f"{directory.name}-identity-{suffix}"
    try:
        with archive.open("rb") as stream:
            output = fixture.docker(
                "run",
                "--rm",
                "-i",
                "--name",
                name,
                "--network",
                "none",
                "--read-only",
                "--cap-drop",
                "ALL",
                "--security-opt",
                "no-new-privileges",
                "--user",
                "1000:1000",
                "--memory",
                "4g",
                "--pids-limit",
                "64",
                "--tmpfs",
                "/proof:rw,noexec,nosuid,nodev,size=3g,uid=1000,gid=1000,mode=0700",
                "--entrypoint",
                "/bin/sh",
                image,
                "-c",
                OPEN_COPY,
                stdin=stream,
                stdout=subprocess.PIPE,
                timeout=660,
            ).stdout
        if len(output) > 1024:
            raise ValueError("isolated identity response exceeds its limit")
        result = json.loads(output)
        if (
            not isinstance(result, dict)
            or set(result) != {"address_fingerprint", "view_key_fingerprint"}
            or any(
                not isinstance(value, str) or not re.fullmatch(r"[0-9a-f]{64}", value)
                for value in result.values()
            )
        ):
            raise ValueError("invalid isolated wallet identity proof")
        return result
    finally:
        # A timed-out Docker client does not stop its container. Never force-kill
        # even these copies; an unproved stop refuses the transition.
        found = fixture.docker(
            "ps", "-aq", "--filter", f"name=^/{name}$", stdout=subprocess.PIPE, timeout=30
        ).stdout.strip()
        if found:
            fixture.docker(
                "kill", "--signal", "TERM", name, stdout=subprocess.DEVNULL, check=False, timeout=30
            )
            fixture.docker("wait", name, stdout=subprocess.DEVNULL, timeout=600)
            fixture.docker("rm", name, stdout=subprocess.DEVNULL, timeout=30)


def prove_live(fixture, state, directory, baseline):
    item = fixture.wallet_container({baseline})
    if item is None or fixture.identity_values(item["Config"]["Env"]) != state["identity"]:
        raise ValueError("live wallet fixture identity differs from the baseline")
    fixture.local_volume()
    was_running = item["State"]["Running"]
    try:
        stopped = fixture.stop_wallet(item, diagnostics=False)
        if stopped["State"]["ExitCode"] != 0 or stopped["State"].get("OOMKilled"):
            raise ValueError("live wallet has no graceful save proof")
        with tempfile.TemporaryDirectory(
            prefix="pithead-wallet-proof-", dir=directory.parent
        ) as work:
            live = Path(work) / "live.tar"
            with live.open("xb") as stream:
                fixture.docker(
                    *fixture.helper(item["Image"], True, directory, "identity-capture"),
                    f"test ! -e {fixture.WALLET_DIR}/.payout-scanning && tar -C {fixture.WALLET_DIR} -cf - payout-wallet payout-wallet.keys",
                    stdout=stream,
                    timeout=180,
                )
            current = fixture.manifest(live)
            encrypted = (
                state["contents"]["payout-wallet.keys"][2] == current["payout-wallet.keys"][2]
            )
            proof = {
                "method": "encrypted_keys" if encrypted else "isolated_open",
                "encrypted_keys_match": encrypted,
                "archived_keys_fingerprint": state["contents"]["payout-wallet.keys"][2],
                "live_keys_fingerprint": current["payout-wallet.keys"][2],
                "identity_proven": True,
            }
            if not encrypted:
                with (directory / "image.tar").open("rb") as stream:
                    fixture.docker(
                        "image", "load", stdin=stream, stdout=subprocess.DEVNULL, timeout=180
                    )
                if fixture.inspect("image", state["image"])["Id"] != state["image"]:
                    raise ValueError("isolated wallet helper differs from the archived image")
                original = open_copy(
                    fixture, state["image"], directory / "wallet.tar", directory, "original"
                )
                successor = open_copy(fixture, state["image"], live, directory, "live")
                if original != successor:
                    raise ValueError(
                        "live wallet address or view key differs from the archived wallet"
                    )
                proof.update(original, address_match=True, view_key_match=True)
            return proof
    finally:
        if was_running:
            fixture.docker("start", item["Id"], stdout=subprocess.DEVNULL, timeout=180)


def supersede(fixture, directory, baseline, job_directory, raw):
    request = request_data(raw)
    info = job_directory.lstat()
    if (
        not stat.S_ISDIR(info.st_mode)
        or info.st_uid != os.getuid()
        or info.st_mode & 0o022
        or job_directory.name != str(request["original_job"])
    ):
        raise ValueError("original supersession job directory is unsafe or mismatched")
    fixture.private(directory.lstat(), True)
    # Serialize wrapper callers without creating lock debris in retained evidence.
    lock_descriptor = os.open(directory, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)
    try:
        fcntl.flock(lock_descriptor, fcntl.LOCK_EX | fcntl.LOCK_NB)
        target = directory / "supersession.json"
        previous = None
        if target.exists() or target.is_symlink():
            previous = json.loads(read_private(fixture, target))
            if not isinstance(previous, dict) or not isinstance(previous.get("proof"), dict):
                raise ValueError("invalid retained supersession record")
        # Validate original evidence on every invocation, including idempotent retries.
        metadata = read_private(fixture, directory / "state.json")
        state = fixture.load(directory, baseline, supersession=True)
        if state["stage"] not in {"captured", "import_verified"}:
            raise ValueError("active or completed restoration cannot be superseded")
        receipt = read_private(fixture, job_directory / "wallet-fixture-restore.state", 11)
        if receipt not in {b"ARMED\n", b"NOT_PROVEN\n"}:
            raise ValueError("original restoration receipt cannot be superseded")
        binding = {
            "schema": 1,
            "request": request,
            "snapshot_fingerprint": hashlib.sha256(metadata).hexdigest(),
            "archive_fingerprint": state["archive_sha256"],
            "original_receipt_fingerprint": hashlib.sha256(receipt).hexdigest(),
        }
        if previous is not None:
            if (
                any(previous.get(key) != value for key, value in binding.items())
                or previous.get("status") != "SUPERSEDED"
                or previous.get("proof", {}).get("identity_proven") is not True
            ):
                raise ValueError("mismatched supersession retry")
            return previous
        proof = prove_live(fixture, state, directory, baseline)
        result = {**binding, "status": "SUPERSEDED", "proof": proof}
        descriptor, temporary = tempfile.mkstemp(prefix=".supersession-", dir=directory)
        try:
            with os.fdopen(descriptor, "w") as stream:
                json.dump(result, stream, sort_keys=True)
                stream.flush()
                os.fsync(stream.fileno())
            Path(temporary).replace(target)
            fixture.sync_directory(directory)
        finally:
            Path(temporary).unlink(missing_ok=True)
        return result

    finally:
        os.close(lock_descriptor)


if __name__ == "__main__":
    os.umask(0o077)
    try:
        if len(sys.argv) != 4:
            raise ValueError("expected baseline, snapshot and original job directory")
        spec = importlib.util.spec_from_file_location(
            "wallet_fixture", Path(__file__).with_name("wallet-fixture.py")
        )
        fixture = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(fixture)
        result = supersede(
            fixture,
            Path(sys.argv[2]),
            Path(sys.argv[1]).resolve(),
            Path(sys.argv[3]),
            sys.stdin.buffer.read(16385),
        )
        print(json.dumps(result, sort_keys=True))
    except (ValueError, OSError, subprocess.SubprocessError, tarfile.TarError, KeyError, TypeError):
        # Refusals never echo untrusted fields, Docker output, wallet logs or secrets.
        print(json.dumps({"schema": 1, "status": "REFUSED", "identity_proven": False}))
        sys.exit(1)
