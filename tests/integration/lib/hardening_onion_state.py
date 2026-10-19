import hashlib
import json
import os
import shutil
import stat
import subprocess
import sys
import tempfile
from pathlib import Path


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def canonical(path):
    if not path.is_absolute() or path == Path("/") or path.resolve(strict=True) != path:
        raise ValueError("noncanonical path")
    return path


def identity(path):
    if not path.exists() and not path.is_symlink():
        return None
    entries = []
    for item in [path, *sorted(path.rglob("*"))]:
        info = item.lstat()
        if not (stat.S_ISREG(info.st_mode) or stat.S_ISDIR(info.st_mode)):
            raise ValueError("unsupported identity inode")
        entries.append(
            (
                str(item.relative_to(path)),
                info.st_mode,
                info.st_uid,
                info.st_gid,
                digest(item) if item.is_file() else None,
            )
        )
    return hashlib.sha256(json.dumps(entries).encode()).hexdigest()


def copy_tree(source, target):
    shutil.copytree(source, target)
    for item in [source, *source.rglob("*")]:
        info = item.stat()
        os.chown(target / item.relative_to(source), info.st_uid, info.st_gid)
    if identity(source) != identity(target):
        raise ValueError("identity copy differs")


def atomic_copy(source, target):
    descriptor, name = tempfile.mkstemp(prefix=f".{target.name}.hardening-", dir=target.parent)
    os.close(descriptor)
    temporary = Path(name)
    try:
        shutil.copy2(source, temporary)
        info = source.stat()
        os.chown(temporary, info.st_uid, info.st_gid)
        with temporary.open("rb") as stream:
            os.fsync(stream.fileno())
        os.replace(temporary, target)
    finally:
        temporary.unlink(missing_ok=True)


def write_state(snapshot, state):
    temporary = snapshot / "state.new"
    temporary.write_text(json.dumps(state))
    temporary.chmod(0o600)
    os.replace(temporary, snapshot / "state.json")


def unmounted(snapshot):
    ids = subprocess.run(
        ["docker", "ps", "-aq"],  # noqa: S607
        check=True,
        capture_output=True,
        text=True,
    ).stdout.split()
    if not ids:
        raise ValueError("container inventory empty")
    containers = subprocess.run(  # noqa: S603
        ["docker", "inspect", *ids],  # noqa: S607
        check=True,
        capture_output=True,
        text=True,
    )
    inspected = json.loads(containers.stdout)
    if len(inspected) != len(ids):
        raise ValueError("container inventory incomplete")
    for container in inspected:
        for mount in container["Mounts"]:
            if mount.get("Type") == "tmpfs" and not mount.get("Source"):
                continue
            if mount.get("Type") not in ("bind", "volume") or not mount.get("Source"):
                raise ValueError("unsupported container mount")
            source = Path(mount["Source"]).resolve(strict=True)
            if snapshot.is_relative_to(source) or source.is_relative_to(snapshot):
                raise ValueError("snapshot overlaps a mount")


def save(tor):
    tor = canonical(Path(tor))
    checkout = canonical(Path.cwd())
    env = checkout / ".env"
    if env.is_symlink() or not env.is_file() or stat.S_IMODE(env.stat().st_mode) != 0o600:
        raise ValueError("unsafe environment file")
    fingerprint = identity(tor / "dashboard")
    snapshot = Path(tempfile.mkdtemp(prefix=".hardening-onion-", dir=checkout))
    unmounted(snapshot)
    shutil.copy2(env, snapshot / "env")
    info = env.stat()
    os.chown(snapshot / "env", info.st_uid, info.st_gid)
    config = checkout / "config.json"
    if config.is_symlink() or not config.is_file():
        raise ValueError("unsafe configuration file")
    shutil.copy2(config, snapshot / "config")
    config_info = config.stat()
    os.chown(snapshot / "config", config_info.st_uid, config_info.st_gid)
    (snapshot / "config").chmod(0o600)
    if fingerprint is not None:
        copy_tree(tor / "dashboard", snapshot / "identity")
    state = {
        "tor": str(tor),
        "env": digest(env),
        "owner": [info.st_uid, info.st_gid],
        "mode": stat.S_IMODE(info.st_mode),
        "identity": fingerprint,
        "phase": "armed",
    }
    if digest(snapshot / "env") != state["env"]:
        raise ValueError("environment copy differs")
    write_state(snapshot, state)
    print(snapshot)


def load(snapshot):
    canonical(snapshot)
    info = snapshot.stat()
    if (
        snapshot.parent != Path.cwd()
        or not snapshot.name.startswith(".hardening-onion-")
        or info.st_uid != os.geteuid()
        or stat.S_IMODE(info.st_mode) != 0o700
    ):
        raise ValueError("unprotected snapshot")
    for name in ("env", "config", "state.json"):
        item = snapshot / name
        if item.is_symlink() or not item.is_file():
            raise ValueError("missing protected snapshot file")
    state = json.loads((snapshot / "state.json").read_text())
    tor = canonical(Path(state["tor"]))
    if (
        digest(snapshot / "env") != state["env"]
        or identity(snapshot / "identity") != state["identity"]
    ):
        raise ValueError("damaged snapshot")
    return state, tor / "dashboard"


def restore(snapshot, state, target):
    if state["phase"] not in ("armed", "restoring", "restored", "verified"):
        raise ValueError("unknown restore state")
    subprocess.run(
        ["docker", "compose", "stop", "tor"],  # noqa: S607
        check=True,
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
    )
    current = identity(target)
    if state["phase"] == "armed":
        state["quarantine"] = current
        if current is not None:
            copy_tree(target, snapshot / "quarantine")
        state["phase"] = "restoring"
        write_state(snapshot, state)
    if current not in (None, state["identity"], state["quarantine"]):
        raise ValueError("identity changed outside restore")
    if identity(snapshot / "quarantine") != state["quarantine"]:
        raise ValueError("quarantine differs")
    staging = target.parent / f"{snapshot.name}-restore"
    if state["identity"] is not None:
        if staging.exists() or staging.is_symlink():
            if identity(staging) != state["identity"]:
                raise ValueError("unexpected staging identity")
        else:
            copy_tree(snapshot / "identity", staging)
    if current is not None:
        shutil.rmtree(target)
    if state["identity"] is not None:
        os.replace(staging, target)
    atomic_copy(snapshot / "env", Path.cwd() / ".env")
    atomic_copy(snapshot / "config", Path.cwd() / "config.json")
    state["phase"] = "restored"
    write_state(snapshot, state)


def verify(snapshot, state, target):
    env = Path.cwd() / ".env"
    info = env.lstat()
    if (
        env.is_symlink()
        or digest(env) != state["env"]
        or [info.st_uid, info.st_gid] != state["owner"]
        or stat.S_IMODE(info.st_mode) != state["mode"]
        or identity(target) != state["identity"]
    ):
        raise ValueError("baseline state differs")
    state["phase"] = "verified"
    write_state(snapshot, state)


def main():
    os.umask(0o077)
    action, argument = sys.argv[1:]
    if action == "save":
        save(argument)
        return
    snapshot = Path(argument)
    state, target = load(snapshot)
    if action == "restore":
        restore(snapshot, state, target)
    elif action == "verify":
        verify(snapshot, state, target)
    elif action == "cleanup" and state["phase"] == "verified":
        verify(snapshot, state, target)
        unmounted(snapshot)
        shutil.rmtree(snapshot)
    else:
        raise ValueError("invalid state operation")


if __name__ == "__main__":
    try:
        main()
    except (OSError, ValueError, KeyError, subprocess.SubprocessError):
        print("hardening onion state operation failed; recovery copies retained", file=sys.stderr)
        sys.exit(1)
