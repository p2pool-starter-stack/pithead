import http.client
import json
import os
import re
import secrets
import selectors
import shutil
import signal
import stat
import subprocess
import sys
import tempfile
import time
import uuid
from pathlib import Path

MARKER = Path(".itest-backup-ownership")
STAGE = "preflight"
ACTOR = "backup-regression"


def require(value):
    if not value:
        raise RuntimeError(STAGE)


def command(args, *, data=None, privileged=False, timeout=300, env=None):
    return subprocess.run(  # noqa: S603
        (["sudo", "-n"] if privileged else []) + args,
        input=data,
        stdout=subprocess.PIPE,
        stderr=subprocess.DEVNULL,
        timeout=timeout,
        env=env,
        check=False,
    )


def api(method, path):
    conn = http.client.HTTPConnection("127.0.0.1", 8000, timeout=5)
    try:
        conn.request(
            method,
            path,
            body=b"{}" if method == "POST" else None,
            headers={
                "Content-Type": "application/json",
                "X-Pithead-Control": "1",
                "X-Auth-User": ACTOR,
            },
        )
        response = conn.getresponse()
        require(response.status in (200, 202))
        return json.loads(response.read(1048576))
    finally:
        conn.close()


def env_paths():
    wanted = {"CONTROL_DIR", "TOR_DATA_DIR", "DASHBOARD_DATA_DIR"}
    return {
        key: value.strip().strip("\"'")
        for line in Path(".env").read_text().splitlines()
        if "=" in line
        for key, value in [line.split("=", 1)]
        if key in wanted
    }


def wait_healthy():
    deadline = time.monotonic() + 360
    while time.monotonic() < deadline:
        if command(["./pithead", "status"], timeout=30).returncode == 0:
            return
        time.sleep(5)
    raise RuntimeError(STAGE)


def wait_gui(request_id):
    deadline = time.monotonic() + 360
    while time.monotonic() < deadline:
        try:
            result = api("GET", "/api/control/result?id=" + request_id)
        except (OSError, http.client.HTTPException, json.JSONDecodeError):
            time.sleep(1)
            continue
        if result.get("status") not in ("pending", "running"):
            require(result.get("status") == "applied" and bool(result.get("passphrase")))
            return result["passphrase"]
        time.sleep(0.5)
    raise RuntimeError(STAGE)


def wait_runner(require_success=True):
    deadline = time.monotonic() + 360
    while time.monotonic() < deadline:
        state = command(
            ["systemctl", "show", "--property=ActiveState", "--value", "pithead-control.service"],
            timeout=10,
        )
        if state.returncode == 0 and state.stdout.strip() in (b"inactive", b"failed"):
            if not require_success:
                return
            status = command(
                ["systemctl", "show", "-p", "ExecMainStatus", "--value", "pithead-control.service"],
                timeout=10,
            )
            require(status.returncode == 0 and status.stdout.strip() == b"0")
            return
        time.sleep(1)
    raise RuntimeError(STAGE)


def members(archive, passphrase, privileged):
    decrypt = subprocess.Popen(  # noqa: S603
        (["sudo", "-n"] if privileged else [])
        + [
            "openssl",
            "enc",
            "-d",
            "-aes-256-cbc",
            "-pbkdf2",
            "-iter",
            "600000",
            "-pass",
            "stdin",
            "-in",
            str(archive),
        ],
        stdin=subprocess.PIPE,
        stdout=subprocess.PIPE,
        stderr=subprocess.DEVNULL,
    )
    listing = subprocess.Popen(
        ["/usr/bin/tar", "-tzf", "-"],
        stdin=decrypt.stdout,
        stdout=subprocess.PIPE,
        stderr=subprocess.DEVNULL,
    )
    decrypt.stdout.close()
    try:
        decrypt.stdin.write(passphrase.encode() + b"\n")
        decrypt.stdin.close()
        names = bytearray()
        deadline = time.monotonic() + 300
        with selectors.DefaultSelector() as reader:
            reader.register(listing.stdout, selectors.EVENT_READ)
            while True:
                remaining = deadline - time.monotonic()
                require(remaining > 0 and reader.select(remaining))
                chunk = os.read(listing.stdout.fileno(), 65536)
                if not chunk:
                    break
                names.extend(chunk)
                require(len(names) <= 1048576)
        require(listing.wait(timeout=10) == 0 and decrypt.wait(timeout=10) == 0)
        return names.decode().splitlines()
    finally:
        for child in (listing, decrypt):
            if child.poll() is None:
                child.kill()
            child.wait(timeout=10)
            for stream in (child.stdin, child.stdout):
                if stream is not None:
                    stream.close()


def validate_archive(archive, passphrase, surface, paths):
    observed = command(["stat", "-c", "%u:%g:%a", str(archive)], privileged=surface == "gui")
    require(observed.returncode == 0)
    expected = b"0:1000:640" if surface == "gui" else f"{os.getuid()}:{os.getgid()}:600".encode()
    require(observed.stdout.strip() == expected)
    names = members(archive, passphrase, surface == "gui")
    for item in ("config.json", ".env", "Caddyfile"):
        require(str(Path.cwd() / item).lstrip("/") in names)
    require(
        any(
            name.startswith(str(Path(paths["TOR_DATA_DIR"])).lstrip("/") + "/")
            and name.endswith("/hs_ed25519_secret_key")
            for name in names
        )
    )
    require(
        any(
            name.startswith(str(Path(paths["DASHBOARD_DATA_DIR"])).lstrip("/") + "/")
            and name.endswith("/mining_data.db")
            for name in names
        )
    )


def recover_request(state):
    deadline = time.monotonic() + 360
    while time.monotonic() < deadline:
        audit = command(
            ["tail", "-c", "1048576", "--", str(Path(state["control"]) / "audit/control.log")],
            privileged=True,
            timeout=10,
        )
        found = set()
        for line in audit.stdout.splitlines():
            try:
                record = json.loads(line)
            except (ValueError, UnicodeError):
                continue
            if record.get("actor") == state["actor"] and record.get("action") == "backup":
                found.add(str(uuid.UUID(record["id"])))
        if found - set(state["requests"]):
            state["requests"] = sorted(found | set(state["requests"]))
            wait_runner(False)
            return
        time.sleep(1)
    raise RuntimeError(STAGE)


def save_state(fixture, state):
    temporary = fixture / "state.tmp"
    temporary.write_text(json.dumps(state))
    temporary.replace(fixture / "state.json")


def cleanup():
    if not MARKER.exists() and not MARKER.is_symlink():
        return
    require(MARKER.is_file() and not MARKER.is_symlink() and MARKER.stat().st_uid == os.getuid())
    name = MARKER.read_text().strip()
    require(re.fullmatch(r"\.backup-ownership-[A-Za-z0-9_]+", name))
    fixture = Path(name)
    require(fixture.is_dir() and not fixture.is_symlink() and fixture.stat().st_uid == os.getuid())
    state_file = fixture / "state.json"
    require(
        state_file.is_file()
        and not state_file.is_symlink()
        and state_file.stat().st_uid == os.getuid()
    )
    state = json.loads(state_file.read_text())
    cdir = Path(state["control"])
    if state["armed"] or state["requests"]:
        wait_runner(False)
    if state.get("post_pending"):
        recover_request(state)
        state["post_pending"] = False
        save_state(fixture, state)
    for request_id in state["requests"]:
        require(str(uuid.UUID(request_id)) == request_id)
        for suffix in (".json", ".tar.gz.enc"):
            require(
                command(
                    ["rm", "-f", "--", str(cdir / "results" / (request_id + suffix))],
                    privileged=True,
                ).returncode
                == 0
            )
    require(
        command(["rm", "-f", "--", str(cdir / "staged/.backup-stamp")], privileged=True).returncode
        == 0
    )
    if (fixture / "stamp").exists():
        require(
            command(
                ["cp", "-p", "--", str(fixture / "stamp"), str(cdir / "staged/.backup-stamp")],
                privileged=True,
            ).returncode
            == 0
        )
    saved = fixture / "backups"
    if saved.exists() or (state["armed"] and not state["had_backups"]):
        require(not Path("backups").is_symlink())
        require(
            command(["rm", "-rf", "--", str(Path.cwd() / "backups")], privileged=True).returncode
            == 0
        )
        if state["had_backups"]:
            saved.rename("backups")
    if state["had_backups"]:
        entry = Path("backups").stat()
        require(
            [entry.st_uid, entry.st_gid, stat.S_IMODE(entry.st_mode), entry.st_ino]
            == state["original"]
        )
    else:
        require(not Path("backups").exists())
    MARKER.unlink()
    shutil.rmtree(fixture)
    print("BACKUP_OWNERSHIP|restoration|pass", flush=True)


def run():
    global STAGE, ACTOR
    require(os.getuid() != 0 and not MARKER.exists() and not MARKER.is_symlink())
    require(Path("config.json").stat().st_uid == os.getuid())
    require(command(["true"], privileged=True).returncode == 0)
    unit = command(["systemctl", "cat", "pithead-control.service"], timeout=10)
    require(
        unit.returncode == 0
        and f"ExecStart={Path.cwd()}/pithead control-run-pending".encode() in unit.stdout
    )
    paths = env_paths()
    require(all(paths.get(key) for key in ("CONTROL_DIR", "TOR_DATA_DIR", "DASHBOARD_DATA_DIR")))
    backup_dir = Path.cwd() / "backups"
    require(not backup_dir.is_symlink())
    require(all(backup_dir != Path(value).resolve() for value in paths.values()))
    containers = command(["docker", "compose", "ps", "-aq"], timeout=30)
    require(containers.returncode == 0 and containers.stdout.strip())
    mounts = command(
        ["docker", "inspect", "--format", "{{json .Mounts}}"] + containers.stdout.decode().split(),
        timeout=30,
    )
    require(mounts.returncode == 0)
    for line in mounts.stdout.decode().splitlines():
        for mount in json.loads(line):
            require(
                not Path(mount["Source"]).is_relative_to(backup_dir)
                and not backup_dir.is_relative_to(Path(mount["Source"]))
            )
    wait_runner()
    original = backup_dir.stat() if backup_dir.exists() else None
    fixture = Path(tempfile.mkdtemp(prefix=".backup-ownership-", dir=Path.cwd()))
    ACTOR = fixture.name
    state = {
        "control": paths["CONTROL_DIR"],
        "actor": ACTOR,
        "post_pending": False,
        "requests": [],
        "armed": False,
        "had_backups": original is not None,
        "original": [
            original.st_uid,
            original.st_gid,
            stat.S_IMODE(original.st_mode),
            original.st_ino,
        ]
        if original
        else None,
    }
    save_state(fixture, state)
    MARKER.write_text(fixture.name)
    try:
        STAGE = "preserve-directory"
        if original:
            backup_dir.rename(fixture / "backups")
        state["armed"] = True
        save_state(fixture, state)
        stamp = Path(paths["CONTROL_DIR"]) / "staged/.backup-stamp"
        if command(["test", "-e", str(stamp)], privileged=True).returncode == 0:
            require(
                command(
                    ["mv", "--", str(stamp), str(fixture / "stamp")], privileged=True
                ).returncode
                == 0
            )
        for order in (("gui", "cli", "gui"), ("cli", "gui", "gui")):
            for step, surface in enumerate(order, 1):
                STAGE = "-".join(order) + "-" + str(step)
                require(command(["rm", "-f", "--", str(stamp)], privileged=True).returncode == 0)
                if surface == "gui":
                    state["post_pending"] = True
                    save_state(fixture, state)
                    request_id = str(uuid.UUID(api("POST", "/api/control/backup")["id"]))
                    state["requests"].append(request_id)
                    state["post_pending"] = False
                    save_state(fixture, state)
                    passphrase = wait_gui(request_id)
                    archive = Path(paths["CONTROL_DIR"]) / "results" / (request_id + ".tar.gz.enc")
                    wait_runner()
                else:
                    before = set(backup_dir.glob("pithead-backup-*.tar.gz.enc"))
                    passphrase = secrets.token_urlsafe(24)
                    env = {**os.environ, "PITHEAD_BACKUP_PASSPHRASE": passphrase}
                    require(command(["./pithead", "backup", "-y"], env=env).returncode == 0)
                    created = set(backup_dir.glob("pithead-backup-*.tar.gz.enc")) - before
                    require(len(created) == 1)
                    archive = created.pop()
                validate_archive(archive, passphrase, surface, paths)
                wait_healthy()
                print(f"BACKUP_OWNERSHIP|{'-'.join(order)}|{step}|{surface}|pass", flush=True)
                time.sleep(1)
            require(command(["rm", "-rf", "--", str(backup_dir)], privileged=True).returncode == 0)
    finally:
        failed_stage = STAGE
        STAGE = "restoration"
        cleanup()
        STAGE = failed_stage


if __name__ == "__main__":
    signal.signal(signal.SIGTERM, lambda *_: (_ for _ in ()).throw(InterruptedError()))
    signal.signal(signal.SIGINT, lambda *_: (_ for _ in ()).throw(InterruptedError()))
    try:
        if sys.argv[1:] == ["--cleanup"]:
            cleanup()
        else:
            run()
    except Exception:
        print(f"BACKUP_OWNERSHIP|error|{STAGE}", flush=True)
        raise SystemExit(1) from None
