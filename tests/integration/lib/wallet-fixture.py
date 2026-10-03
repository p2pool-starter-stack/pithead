"""Keep the prepared, view-only Monero cache across destructive bench scenarios."""

import hashlib
import json
import os
import re
import shlex
import stat
import subprocess
import sys
import tarfile
import tempfile
import time
from pathlib import Path, PurePosixPath

WALLET_DIR = "/home/ubuntu/wallets"
VOLUME = "pithead_wallet_data"
IDENTITY_FIELDS = {
    "MONERO_WALLET_ADDRESS",
    "MONERO_VIEW_KEY",
    "PAYOUT_SCAN_HEIGHT",
    "WALLET_RPC_USERNAME",
    "WALLET_RPC_PASSWORD",
}


def docker(*args, **kwargs):
    # Only fixed native Docker operations; snapshot image/mount arguments are validated below.
    return subprocess.run(["docker", *args], check=True, stderr=subprocess.DEVNULL, **kwargs)  # noqa: S603,S607


def inspect(kind, name):
    return json.loads(docker(kind, "inspect", name, stdout=subprocess.PIPE).stdout)[0]


def identity_values(lines):
    values = {}
    for line in lines:
        key, sep, value = line.partition("=")
        if sep and key in IDENTITY_FIELDS:
            if key in values:
                raise ValueError("duplicate wallet identity field")
            parts = shlex.split(value)
            if len(parts) > 1:
                raise ValueError("invalid wallet identity field")
            values[key] = parts[0] if parts else ""
    if not values.get("MONERO_VIEW_KEY"):
        return None
    if not values.get("MONERO_WALLET_ADDRESS"):
        raise ValueError("configured wallet identity is incomplete")
    if set(values) != IDENTITY_FIELDS:
        raise ValueError("configured wallet identity is incomplete")
    return hashlib.sha256(json.dumps(values, sort_keys=True).encode()).hexdigest()


def identity(baseline):
    return identity_values((baseline / ".env").read_text().splitlines())


def stream_digest(stream):
    value = hashlib.sha256()
    for block in iter(lambda: stream.read(1024 * 1024), b""):
        value.update(block)
    return value.hexdigest()


def digest(path):
    with path.open("rb") as stream:
        return stream_digest(stream)


def manifest(path):
    result = {}
    size = 0
    with tarfile.open(path, "r|") as archive:
        for member in archive:
            name = PurePosixPath(member.name)
            if name.is_absolute() or ".." in name.parts or not member.isfile():
                raise ValueError("unsafe wallet archive member")
            name = str(name)
            # ponytail: cap fixture contents at 2 GiB; raise only for measured larger caches.
            size += member.size
            if size > 2 * 1024**3:
                raise ValueError("wallet fixture archive is too large")
            if name in result or member.uid != 1000 or member.gid != 1000 or member.mode != 0o600:
                raise ValueError("unexpected wallet archive ownership or mode")
            stream = archive.extractfile(member)
            if stream is None:
                raise ValueError("unreadable wallet archive member")
            result[name] = [member.mode, member.size, stream_digest(stream)]
    if set(result) != {"payout-wallet", "payout-wallet.keys"} or not all(
        value[1] for value in result.values()
    ):
        raise ValueError("wallet archive must contain only the prepared cache and keys")
    return result


def wallet_container(allowed):
    ids = (
        docker("ps", "-aq", "--filter", f"volume={VOLUME}", stdout=subprocess.PIPE)
        .stdout.decode()
        .split()
    )
    if len(ids) > 1:
        raise ValueError("wallet volume has another consumer")
    if not ids:
        return None
    item = inspect("container", ids[0])
    labels = item["Config"]["Labels"] or {}
    if (
        labels.get("com.docker.compose.project") != "pithead"
        or labels.get("com.docker.compose.service") != "wallet-rpc"
    ):
        raise ValueError("wallet volume has an unexpected consumer")
    if Path(labels.get("com.docker.compose.project.working_dir", "")).resolve() not in allowed:
        raise ValueError("wallet consumer belongs to another checkout")
    mounts = [m for m in item["Mounts"] if m["Destination"] == WALLET_DIR]
    if len(mounts) != 1 or mounts[0]["Type"] != "volume" or mounts[0]["Name"] != VOLUME:
        raise ValueError("wallet volume definition changed")
    return item


def stop_wallet(item):
    if item["State"]["Running"]:
        # `docker stop` marks the stop as manual, so the wallet's `restart: unless-stopped`
        # policy does not revive it (a bare `docker kill` does, and the wait below never ended).
        # A wallet that outlives the window is killed and exits nonzero; capture then refuses it.
        docker("stop", "--time", "120", item["Id"], stdout=subprocess.DEVNULL)
    deadline = time.monotonic() + 120
    while True:
        item = inspect("container", item["Id"])
        if not item["State"]["Running"] and not item["State"].get("Restarting"):
            return item
        if time.monotonic() >= deadline:
            raise ValueError("wallet did not stop gracefully; no forced kill attempted")
        time.sleep(1)


def helper(image, readonly, directory, action):
    if not re.fullmatch(r"sha256:[0-9a-f]{64}", image):
        raise ValueError("wallet helper image is not pinned")
    mount = f"type=volume,src={VOLUME},dst={WALLET_DIR}"
    if readonly:
        mount += ",readonly"
    return [
        "run",
        "--rm",
        "-i",
        "--name",
        f"{directory.name}-{action}",
        "--label",
        f"pithead.wallet-fixture={directory.name}",
        "--network",
        "none",
        "--read-only",
        "--cap-drop",
        "ALL",
        "--security-opt",
        "no-new-privileges",
        "--memory",
        "128m",
        "--pids-limit",
        "64",
        "--user",
        "1000:1000",
        "--mount",
        mount,
        "--entrypoint",
        "/bin/sh",
        image,
        "-c",
    ]


def local_volume():
    volume = inspect("volume", VOLUME)
    if volume["Driver"] != "local" or volume.get("Options"):
        raise ValueError("wallet fixture requires an independent local Docker volume")
    labels = volume.get("Labels") or {}
    if (
        labels.get("com.docker.compose.project") != "pithead"
        or labels.get("com.docker.compose.volume") != "wallet_data"
    ):
        raise ValueError("wallet volume belongs to another project")


def sync_directory(directory):
    descriptor = os.open(directory, os.O_RDONLY)
    try:
        os.fsync(descriptor)
    finally:
        os.close(descriptor)


def write_state(directory, data):
    temporary = directory / "state.tmp"
    with temporary.open("w") as stream:
        json.dump(data, stream, sort_keys=True)
        stream.flush()
        os.fsync(stream.fileno())
    temporary.replace(directory / "state.json")
    sync_directory(directory)


def receipt(directory, stage):
    if stage not in {"ARMED", "READY", "VERIFIED", "NOT_PROVEN"}:
        raise ValueError("unknown wallet restoration receipt")
    info = directory.lstat()
    if not stat.S_ISDIR(info.st_mode) or info.st_uid != os.getuid() or info.st_mode & 0o022:
        raise ValueError("wallet restoration job directory is unsafe")
    target = directory / "wallet-fixture-restore.state"
    previous = None
    if target.exists() or target.is_symlink():
        descriptor = os.open(target, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
        with os.fdopen(descriptor, "rb") as stream:
            info = os.fstat(stream.fileno())
            private(info)
            if info.st_size > 11:
                raise ValueError("wallet restoration receipt is unsafe")
            previous = stream.read(12).decode("ascii")
    permitted = {
        "ARMED": {None, "VERIFIED\n"},
        "READY": {"ARMED\n", "READY\n"},
        "VERIFIED": {"READY\n"},
        "NOT_PROVEN": {"ARMED\n", "READY\n", "NOT_PROVEN\n"},
    }
    if previous not in permitted[stage]:
        raise ValueError("wallet restoration receipt transition refused")
    descriptor, name = tempfile.mkstemp(prefix=".wallet-fixture-", dir=directory)
    try:
        with os.fdopen(descriptor, "w") as stream:
            stream.write(stage + "\n")
            stream.flush()
            os.fsync(stream.fileno())
        Path(name).replace(target)
        sync_directory(directory)
    finally:
        Path(name).unlink(missing_ok=True)


def private(info, directory=False):
    kind = stat.S_ISDIR if directory else stat.S_ISREG
    if (
        not kind(info.st_mode)
        or info.st_uid != os.getuid()
        or stat.S_IMODE(info.st_mode) != (0o700 if directory else 0o600)
    ):
        raise ValueError("wallet fixture snapshot is not owner-only")


def capture(baseline):
    fingerprint = identity(baseline)
    if fingerprint is None:
        return
    item = wallet_container({baseline})
    if item is None:
        raise ValueError("configured wallet container is missing")
    if identity_values(item["Config"]["Env"]) != fingerprint:
        raise ValueError("source container wallet identity differs from the baseline")
    local_volume()
    directory = Path(
        tempfile.mkdtemp(
            prefix="pithead-wallet-fixture-",
            dir=os.environ.get("IT_SCRATCH_DIR") or "/var/tmp",  # noqa: S108 -- mkdtemp creates an owner-only directory under the persistent sticky temp root.
        )
    )
    was_running = item["State"]["Running"]
    try:
        stopped = stop_wallet(item)
        if stopped["State"]["ExitCode"] != 0 or stopped["State"].get("OOMKilled"):
            raise ValueError("source wallet has no graceful save proof")
        archive = directory / "wallet.tar"
        with archive.open("xb") as stream:
            command = f"test ! -e {WALLET_DIR}/.payout-scanning && tar -C {WALLET_DIR} -cf - payout-wallet payout-wallet.keys"
            docker(*helper(item["Image"], True, directory, "capture"), command, stdout=stream)
            stream.flush()
            os.fsync(stream.fileno())
        contents = manifest(archive)
        # Uninstall also removes owned images. Keep the exact tar-capable image offline.
        with (directory / "image.tar").open("xb") as stream:
            docker("image", "save", item["Image"], stdout=stream)
            stream.flush()
            os.fsync(stream.fileno())
        write_state(
            directory,
            {
                "baseline": str(baseline),
                "directory": str(directory),
                "identity": fingerprint,
                "image": item["Image"],
                "archive_sha256": digest(archive),
                "image_sha256": digest(directory / "image.tar"),
                "contents": contents,
                "stage": "captured",
            },
        )
        sync_directory(directory.parent)
    except Exception:
        # No branch was deployed; remove only this capture's known private files.
        for name in ("wallet.tar", "image.tar", "state.tmp", "state.json"):
            path = directory / name
            if path.exists() or path.is_symlink():
                private(path.lstat())
                path.unlink()
        directory.rmdir()
        sync_directory(directory.parent)
        raise
    finally:
        if was_running:
            docker("start", item["Id"], stdout=subprocess.DEVNULL)
    print(directory)


def load(directory, baseline, cleanup_only=False):
    if directory.name == "" or not directory.name.startswith("pithead-wallet-fixture-"):
        raise ValueError("unexpected wallet fixture snapshot path")
    private(directory.lstat(), True)
    private((directory / "state.json").lstat())
    state = json.loads((directory / "state.json").read_text())
    if state["directory"] != str(directory) or state["stage"] not in {
        "captured",
        "restoring",
        "import_verified",
        "ready",
    }:
        raise ValueError("wallet fixture receipt changed")
    if state["baseline"] != str(baseline) or state["identity"] != identity(baseline):
        raise ValueError("baseline wallet identity changed")
    if state["stage"] == "ready":
        if cleanup_only:
            return state
        raise ValueError("proved fixture is awaiting cleanup; do not import it again")
    private((directory / "wallet.tar").lstat())
    private((directory / "image.tar").lstat())
    if state["archive_sha256"] != digest(directory / "wallet.tar") or state["contents"] != manifest(
        directory / "wallet.tar"
    ):
        raise ValueError("wallet fixture snapshot changed")
    if not re.fullmatch(r"sha256:[0-9a-f]{64}", state["image"]) or state["image_sha256"] != digest(
        directory / "image.tar"
    ):
        raise ValueError("wallet helper image snapshot changed")
    return state


def restore(directory, baseline, branch):
    state = load(directory, baseline)
    item = wallet_container({baseline, branch})
    if item:
        stop_wallet(item)
    with (directory / "image.tar").open("rb") as stream:
        docker("image", "load", stdin=stream, stdout=subprocess.DEVNULL)
    if inspect("image", state["image"])["Id"] != state["image"]:
        raise ValueError("restored wallet helper image differs from its source")
    docker(
        "volume",
        "create",
        "--driver",
        "local",
        "--label",
        "com.docker.compose.project=pithead",
        "--label",
        "com.docker.compose.volume=wallet_data",
        VOLUME,
        stdout=subprocess.DEVNULL,
    )
    local_volume()
    current = wallet_container({baseline, branch})
    if current and (current["State"]["Running"] or current["State"].get("Restarting")):
        raise ValueError("wallet consumer restarted before fixture import")
    state["stage"] = "restoring"
    write_state(directory, state)
    command = f"find {WALLET_DIR} -mindepth 1 -maxdepth 1 -exec rm -rf -- {{}} + && tar -C {WALLET_DIR} --no-same-owner -xf - && sync {WALLET_DIR}/payout-wallet {WALLET_DIR}/payout-wallet.keys {WALLET_DIR}"
    with (directory / "wallet.tar").open("rb") as stream:
        docker(
            *helper(state["image"], False, directory, "import"),
            command,
            stdin=stream,
            stdout=subprocess.DEVNULL,
        )
    check = directory / "check.tar"
    with check.open("wb") as stream:
        docker(
            *helper(state["image"], True, directory, "verify"),
            f"tar -C {WALLET_DIR} -cf - payout-wallet payout-wallet.keys",
            stdout=stream,
        )
    if manifest(check) != state["contents"]:
        raise ValueError("restored wallet contents differ from the prepared fixture")
    check.unlink()
    state["stage"] = "import_verified"
    write_state(directory, state)


def cleanup(directory, baseline):
    state = load(directory, baseline, cleanup_only=True)
    if state["stage"] not in {"import_verified", "ready"}:
        raise ValueError("wallet import has not been proved")
    if not set(p.name for p in directory.iterdir()) <= {"state.json", "wallet.tar", "image.tar"}:
        raise ValueError("unexpected files in wallet fixture snapshot")
    state["stage"] = "ready"
    write_state(directory, state)
    for name in ("wallet.tar", "image.tar"):
        path = directory / name
        if path.exists() or path.is_symlink():
            private(path.lstat())
            path.unlink()
    sync_directory(directory)


if __name__ == "__main__":
    os.umask(0o077)
    action, root = sys.argv[1:3]
    root = Path(root) if action == "receipt" else Path(root).resolve()
    try:
        if action == "capture":
            capture(root)
        elif action == "restore":
            restore(Path(sys.argv[3]), root, Path(sys.argv[4]).resolve())
        elif action == "cleanup":
            cleanup(Path(sys.argv[3]), root)
        elif action == "receipt":
            receipt(root, sys.argv[3])
        else:
            raise ValueError("unknown wallet fixture action")
    except (ValueError, OSError, subprocess.CalledProcessError, KeyError) as exc:
        detail = str(exc) if isinstance(exc, ValueError) else type(exc).__name__
        print(f"wallet fixture {action} failed: {detail}", file=sys.stderr)
        sys.exit(1)
