import json
import os
import re
import stat
import subprocess
import sys
import tempfile
import time
from pathlib import Path


def private(path, directory=False):
    info = path.lstat()
    kind = stat.S_ISDIR if directory else stat.S_ISREG
    if not kind(info.st_mode) or info.st_uid != os.geteuid() or info.st_mode & 0o077:
        raise ValueError("unsafe private snapshot state")
    if not directory and info.st_nlink != 1:
        raise ValueError("linked snapshot state")


def atomic(path, value):
    fd, name = tempfile.mkstemp(prefix=".tari-state-", dir=path.parent)
    try:
        with os.fdopen(fd, "w") as stream:
            json.dump(value, stream, sort_keys=True)
            stream.write("\n")
            stream.flush()
            os.fsync(stream.fileno())
        os.replace(name, path)
        fd = os.open(path.parent, os.O_RDONLY | os.O_DIRECTORY)
        try:
            os.fsync(fd)
        finally:
            os.close(fd)
    finally:
        Path(name).unlink(missing_ok=True)


def receipt(target, job, commit, new=None):
    target = Path(target)
    if target.name != "tari-snapshot-restore.json" or not re.fullmatch(r"[0-9a-f]{40}", commit):
        raise ValueError("invalid snapshot identity")
    directory = target.parent.lstat()
    if (
        not stat.S_ISDIR(directory.st_mode)
        or directory.st_uid != os.geteuid()
        or directory.st_mode & 0o022
    ):
        raise ValueError("unsafe snapshot job directory")
    private(target)
    fd = os.open(target, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
    try:
        before = os.fstat(fd)
        if (
            not stat.S_ISREG(before.st_mode)
            or before.st_uid != os.geteuid()
            or stat.S_IMODE(before.st_mode) != 0o600
            or before.st_nlink != 1
        ):
            raise ValueError("unsafe snapshot receipt")
        raw = os.read(fd, 4097)
        after = os.fstat(fd)
        if before != after or len(raw) > 4096 or len(raw) != before.st_size:
            raise ValueError("snapshot receipt changed")
        value = json.loads(raw)
    finally:
        os.close(fd)
    if not isinstance(value, dict):
        raise ValueError("invalid snapshot receipt")
    expected = {"schema": 1, "job_id": int(job), "commit": commit, "state": value.get("state")}
    if (
        value != expected
        or type(value.get("schema")) is not int
        or type(value.get("job_id")) is not int
    ):
        raise ValueError("snapshot receipt identity mismatch")
    if value["state"] not in {"ARMED", "NOT_PROVEN", "VERIFIED"}:
        raise ValueError("unknown snapshot state")
    if new:
        if new not in {"NOT_PROVEN", "VERIFIED"} or value["state"] == "VERIFIED":
            raise ValueError("snapshot receipt transition refused")
        atomic(target, {**expected, "state": new})
    return value["state"]


def command(*args, timeout=15):
    return subprocess.run(args, check=True, capture_output=True, text=True, timeout=timeout).stdout  # noqa: S603


def inspect(name):
    return json.loads(command("docker", "inspect", name))[0]


def mounts():
    rows = []
    node = inspect("tari")
    if not node["State"]["Running"]:
        raise ValueError("baseline Tari is not running")
    for name, destination in (("tari", "/var/tari/node"), ("tari-wallet", "/var/tari/wallet")):
        try:
            item = node if name == "tari" else inspect(name)
        except subprocess.CalledProcessError:
            if name == "tari":
                raise
            if command(
                "docker", "ps", "-a", "--filter", "name=^/tari-wallet$", "--format", "{{.ID}}"
            ).strip():
                raise ValueError("wallet consumer inspection failed") from None
            if command(
                "docker",
                "volume",
                "ls",
                "--filter",
                "name=^pithead_tari_wallet_db$",
                "--format",
                "{{.Name}}",
            ).strip():
                raise ValueError("wallet volume has no inspectable consumer") from None
            continue
        matches = [m for m in item["Mounts"] if m["Destination"] == destination and m["RW"]]
        if len(matches) != 1 or matches[0]["Type"] not in {"bind", "volume"}:
            raise ValueError("Tari writable mount is not uniquely identified")
        mount = matches[0]
        if name == "tari-wallet" and not item["State"]["Running"]:
            raise ValueError("wallet snapshot requires a running baseline consumer")
        source = mount["Source"]
        if not source.startswith("/") or source == "/" or any(c in source for c in "\n\r\t"):
            raise ValueError("unsupported Tari mount source")
        rows.append([name, destination, source, mount["Type"]])
    return rows


def quiesced(root):
    state = json.loads((root / "state.json").read_text())
    ids = command("docker", "ps", "-q").split()
    if not ids:
        return
    for item in json.loads(command("docker", "inspect", *ids)):
        for mount in item["Mounts"]:
            if not mount.get("RW") or mount.get("Type") == "tmpfs":
                continue
            current = Path(mount["Source"]).resolve()
            for row in state["mounts"]:
                source = Path(row[2]).resolve()
                if current == source or current in source.parents or source in current.parents:
                    raise ValueError("Tari state still has a live writer")


def opened():
    probe = """
import os, grpc
from google.protobuf import empty_pb2
from mining_dashboard.client.tari.generated import base_node_pb2_grpc
with grpc.insecure_channel(os.environ['TARI_GRPC_ADDRESS']) as c:
    base_node_pb2_grpc.BaseNodeStub(c).GetTipInfo(empty_pb2.Empty(), timeout=5)
"""
    command("docker", "exec", "dashboard", "python3", "-c", probe, timeout=8)


def readiness():
    probe = """
import json, os, grpc
from mining_dashboard.client.tari.generated import base_node_pb2, base_node_pb2_grpc
with grpc.insecure_channel(os.environ['TARI_GRPC_ADDRESS']) as c:
    status = base_node_pb2_grpc.BaseNodeStub(c).GetNetworkState(base_node_pb2.GetNetworkStateRequest(), timeout=5).readiness_status
    kind = status.WhichOneof('status')
    result = {'ready': kind == 'state' and status.state == base_node_pb2.ReadinessStatus.READY, 'migration': kind == 'migration'}
    result['phase'] = base_node_pb2.ReadinessStatus.State.Name(status.state) if kind == 'state' else 'migration' if kind == 'migration' else 'unknown'
print(json.dumps(result))
"""
    return json.loads(command("docker", "exec", "dashboard", "python3", "-c", probe, timeout=8))


def db_bytes(source):
    out = command(
        "sudo",
        "-n",
        "find",
        source,
        "-type",
        "f",
        "(",
        "-name",
        "*.mdb",
        "-o",
        "-name",
        "*.sqlite*",
        "-o",
        "-name",
        "*.db",
        ")",
        "-printf",
        "%s\n",
        timeout=30,
    )
    return sum(int(line) for line in out.splitlines())


def initialize(root):
    private(root, True)
    rows = mounts()
    opened()
    data = {
        "mounts": rows,
        "baseline": inspect("tari")["Id"],
        "marker": ".pithead-tari-snapshot-" + root.name,
        "input_db_bytes": {row[0]: db_bytes(row[2]) for row in rows},
        "stage": "untouched",
    }
    atomic(root / "state.json", data)
    print("\n".join("\t".join(row) for row in rows))


def sample(root, data):
    result = {"active": True, "sampled_at": time.time()}
    try:
        item = inspect("tari")
        result["container"] = item["Id"]
        result["started"] = item["State"]["StartedAt"]
        if item["State"]["Running"]:
            try:
                pid = int(item["State"]["Pid"])
                for line in Path(f"/proc/{pid}/cgroup").read_text().splitlines():
                    if line.startswith("0::"):
                        group = Path("/sys/fs/cgroup") / line[3:].lstrip("/")
                        result["peak_memory_bytes"] = int((group / "memory.peak").read_text())
            except (OSError, ValueError):
                result["memory_peak_unavailable"] = True
            status = readiness()
            epoch = item["Id"] + "@" + item["State"]["StartedAt"]
            data.setdefault("migration_starts", {}).setdefault(epoch, False)
            data["phases"] = sorted(set(data.get("phases", [])) | {status.get("phase", "unknown")})
            if status.get("migration") is True:
                data.setdefault("migration_start_observed_at", result["sampled_at"])
                data["migration_observed"] = True
                data["migration_starts"][epoch] = True
            if status.get("ready") is True:
                opened()
                if any(row[0] == "tari-wallet" for row in data["mounts"]):
                    wallet = inspect("tari-wallet")
                    result["wallet"] = wallet["Id"]
                    result["wallet_started"] = wallet["State"]["StartedAt"]
                    command(
                        "docker",
                        "exec",
                        "-e",
                        "PAYOUT_SCAN_GRACE_SEC=0",
                        "tari-wallet",
                        "/wallet-config/wallet-healthcheck.sh",
                    )
                result["active"] = False
        if data.get("migration_observed") and not result["active"]:
            data.setdefault("migration_end_observed_at", result["sampled_at"])
    except (OSError, ValueError, subprocess.SubprocessError):
        result["active"] = True
        result["observation_gap"] = True
    free = min(os.statvfs(row[2]).f_bavail * os.statvfs(row[2]).f_frsize for row in data["mounts"])
    data["minimum_free_bytes"] = min(data.get("minimum_free_bytes", free), free)
    data["peak_memory_bytes"] = max(
        data.get("peak_memory_bytes", 0), result.get("peak_memory_bytes", 0)
    )
    if result.get("observation_gap"):
        data["observation_gap"] = True
    atomic(root / "metrics.json", data)
    atomic(root / "migration.json", result)
    return result


def observe(root):
    data = json.loads((root / "metrics.json").read_text())
    try:
        while not (root / "observer.stop").exists():
            sample(root, data)
            time.sleep(2)
    finally:
        atomic(root / "observer.done", {"stopped": True})


def wait_clear(root, bound):
    budget = root / "wait-deadline.json"
    if not budget.exists():
        atomic(budget, {"deadline": time.monotonic() + min(7100, bound)})
    deadline = json.loads(budget.read_text())["deadline"]
    print("Tari migration stop wait started", flush=True)
    while True:
        value = json.loads((root / "migration.json").read_text())
        if (
            value.get("active") is False
            and not value.get("observation_gap")
            and 0 <= time.time() - value.get("sampled_at", 0) < 10
        ):
            item = inspect("tari")
            state = json.loads((root / "state.json").read_text())
            if any(row[0] == "tari-wallet" for row in state["mounts"]):
                wallet = inspect("tari-wallet")
                if (
                    not wallet["State"]["Running"]
                    or value.get("wallet") != wallet["Id"]
                    or value.get("wallet_started") != wallet["State"]["StartedAt"]
                ):
                    value["active"] = True
            if (
                value["active"] is False
                and item["State"]["Running"]
                and value.get("started") == item["State"]["StartedAt"]
                and value.get("container") == item["Id"]
            ):
                print("Tari migration stop wait cleared", flush=True)
                return
        if time.monotonic() >= deadline:
            raise ValueError("Tari migration stop wait expired; restoration NOT PROVEN")
        time.sleep(min(1, max(0, deadline - time.monotonic())))


def restart_check(root):
    command("docker", "restart", "--time", "120", "tari", timeout=150)
    wait_clear(root, 7180)
    item = inspect("tari")
    epoch = item["Id"] + "@" + item["State"]["StartedAt"]
    data = json.loads((root / "metrics.json").read_text())
    atomic(
        root / "restart.json", {"second_restart_migration_seen": data["migration_starts"][epoch]}
    )


def stop_observer(root):
    (root / "observer.stop").touch(mode=0o600)
    deadline = time.monotonic() + 60
    while not (root / "observer.done").exists():
        if time.monotonic() >= deadline:
            raise ValueError("snapshot observer shutdown unproven")
        time.sleep(1)


def main():
    action, directory = sys.argv[1:3]
    if action == "receipt":
        print(receipt(directory, *sys.argv[3:]))
        return
    root = Path(directory)
    private(root, True)
    if action == "init":
        initialize(root)
    elif action == "identity":
        target, job, commit = sys.argv[3:6]
        if receipt(target, job, commit) != "NOT_PROVEN":
            raise ValueError("snapshot identity is not fenced")
        atomic(root / "identity.json", {"schema": 1, "job_id": int(job), "commit": commit})
    elif action == "quiesced":
        quiesced(root)
    elif action == "observe":
        observe(root)
    elif action == "wait":
        wait_clear(root, float(sys.argv[3]))
    elif action == "restart":
        restart_check(root)
    elif action == "stop-observer":
        stop_observer(root)
    elif action == "metrics":
        state = json.loads((root / "state.json").read_text())
        free = min(
            os.statvfs(row[2]).f_bavail * os.statvfs(row[2]).f_frsize for row in state["mounts"]
        )
        data = {
            "started_at": int(time.time()),
            "minimum_free_bytes": free,
            "free_before_bytes": free,
            "input_db_bytes": state["input_db_bytes"],
            "mounts": state["mounts"],
        }
        atomic(root / "metrics.json", data)
        atomic(root / "migration.json", {"active": True, "sampled_at": time.time()})
    elif action == "report":
        state = json.loads((root / "state.json").read_text())
        data = json.loads((root / "metrics.json").read_text())
        data.pop("mounts", None)
        data["output_db_bytes"] = {row[0]: db_bytes(row[2]) for row in state["mounts"]}
        data["finished_at"] = time.time()
        data["peak_memory_bytes"] = data.get("peak_memory_bytes") or None
        data.update(json.loads((root / "restart.json").read_text()))
        data["migration_timing"] = (
            "observed"
            if data.get("migration_end_observed_at") and not data.get("observation_gap")
            else "missing"
        )
        print("Tari snapshot observations: " + json.dumps(data, sort_keys=True))
    else:
        raise ValueError("unknown Tari snapshot operation")


if __name__ == "__main__":
    os.umask(0o077)
    try:
        main()
    except (OSError, ValueError, KeyError, TypeError, subprocess.SubprocessError):
        print("Tari snapshot operation refused; restoration NOT PROVEN", file=sys.stderr)
        raise SystemExit(1) from None
