"""Live Caddy/API regression for bounded failed-login history; hardening phase."""

import gzip
import io
import json
import os
import re
import shutil
import stat
import subprocess
import time
import uuid
import zlib
from pathlib import Path
from urllib.parse import urlencode

_GENERATION = re.compile(r"access-\d{4}-\d{2}-\d{2}T\d{2}-\d{2}-\d{2}\.\d{3}\.log(?:\.gz)?")
OLD_TAIL = 256 * 1024
FILE_BYTES = 4 * 1024 * 1024


def require(condition, message):
    if not condition:
        raise RuntimeError(message)


class Caddy:
    """Use the hardening phase's temporary login via curl stdin, never argv/logs."""

    def __init__(self):
        env = {}
        for line in Path(".env").read_text().splitlines():
            if "=" in line and not line.startswith("#"):
                key, value = line.split("=", 1)
                env[key] = value.strip("'\"")
        config = json.loads(Path("config.json").read_text())
        auth = config["dashboard"]["auth"]
        require(bool(auth["password"]), "dashboard authentication must be enabled")
        self.good = auth["username"] + ":" + auth["password"]
        self.bad = auth["username"] + ":" + uuid.uuid4().hex
        self.host = env["HOST_IP"]
        scheme = "http" if env["DASHBOARD_SECURE"] == "false" else "https"
        self.port = env.get("HOST_PORT") or ("80" if scheme == "http" else "443")
        self.origin = f"{scheme}://{self.host}:{self.port}"
        self.logs = Path(env["CADDY_LOG_DIR"])
        self.curl = shutil.which("curl")
        require(bool(self.curl), "curl is required for the live proxy test")

    def request(self, uri, wrong=False):
        result = subprocess.run(  # noqa: S603 - fixed curl flags, no shell; login stays on stdin.
            [
                self.curl,
                "-ksS",
                "--noproxy",
                "*",
                "--max-time",
                "15",
                "-K",
                "-",
                "--resolve",
                f"{self.host}:{self.port}:127.0.0.1",
                "--write-out",
                "\\n%{http_code}",
                self.origin + uri,
            ],
            input="user = " + json.dumps(self.bad if wrong else self.good) + "\n",
            capture_output=True,
            text=True,
            timeout=20,
            check=False,
        )
        require(result.returncode == 0, "Caddy transport failed")
        body, status = result.stdout.rsplit("\n", 1)
        return int(status), body

    def summary(self, sentinel):
        status, body = self.request("/api/access?" + urlencode({"q": sentinel}))
        require(status == 200, "authenticated access API must return 200")
        return json.loads(body)


def generations(logs):
    return {p.name.removesuffix(".gz") for p in logs.iterdir() if _GENERATION.fullmatch(p.name)}


def log_bytes(path):
    """Bound plain/compressed input and gzip output; refuse links and special files."""
    fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
    with os.fdopen(fd, "rb") as stream:
        require(
            stat.S_ISREG(os.fstat(stream.fileno()).st_mode), "security log must be a regular file"
        )
        data = stream.read(FILE_BYTES + 1)
    require(len(data) <= FILE_BYTES, "security log exceeds the shipped per-file bound")
    if path.suffix == ".gz":
        with gzip.GzipFile(fileobj=io.BytesIO(data)) as stream:
            data = stream.read(FILE_BYTES + 1)
        require(len(data) <= FILE_BYTES, "decompressed log exceeds the shipped per-file bound")
    return data


def retained_paths(logs):
    """Independent witness: active plus two newest unique shipped generations."""
    selected = {}
    for path in logs.iterdir():
        if not _GENERATION.fullmatch(path.name):
            continue
        name = path.name.removesuffix(".gz")
        if name not in selected or path.suffix != ".gz":
            selected[name] = path
        if len(selected) > 2:
            del selected[min(selected)]
    return [logs / "access.log", *(selected[name] for name in sorted(selected))]


def expected_failures(logs, now):
    """Count native Caddy 401 records independently of the dashboard implementation."""
    failures = 0
    for path in retained_paths(logs):
        try:
            data = log_bytes(path)
        except (OSError, EOFError, zlib.error):
            continue
        for line in data.splitlines():
            try:
                entry = json.loads(line)
                if entry["status"] == 401 and 0 <= now - entry["ts"] <= 86400:
                    failures += 1
            except (ValueError, TypeError, KeyError, RecursionError):
                continue
    return failures


def prove(client, *, sleep=time.sleep, clock=time.monotonic, wall_clock=time.time):
    """Fail closed on missing records, active-tail undercounts or rotation undercounts.

    Produce only real requests; never rewrite/truncate the security logs or change
    Caddy's rotation settings. First roll to a fresh active file, then put three
    failures near its beginning. All traffic is bounded by request count and time.
    """
    deadline = clock() + 540
    marker = "/retention-" + uuid.uuid4().hex
    sentinel = marker + "/wrong-password"
    padding = marker + "/padding?fill=" + "p" * 6000
    active = client.logs / "access.log"

    def within_deadline():
        require(clock() < deadline, "live retention test deadline exceeded")

    def pad():
        within_deadline()
        status, _ = client.request(padding)
        require(status in (200, 400, 404), "authenticated padding request failed")

    def rotate():
        before = generations(client.logs)
        for _ in range(800):
            pad()
            if generations(client.logs) != before:
                return
        raise RuntimeError("Caddy did not rotate within the bounded request budget")

    def wait_for(predicate, message):
        for _ in range(60):
            within_deadline()
            if predicate():
                return
            sleep(0.25)
        raise RuntimeError(message)

    def retained():
        summary = client.summary(sentinel)
        entries = summary.get("entries", [])
        return (
            summary.get("available") is True
            and summary.get("failures_24h") == expected_failures(client.logs, wall_clock())
            and len(entries) == 3
            and all(e.get("status") == 401 and e.get("uri") == sentinel for e in entries)
        )

    rotate()
    for _ in range(3):
        status, _ = client.request(sentinel, wrong=True)
        require(status == 401, "wrong password must receive a real Caddy 401")
    wait_for(retained, "live API did not count all three wrong-password failures")
    print("access-log-retention: real wrong-password failures counted", flush=True)

    # A fresh active file leaves plenty of room before the next 4 MiB rotation.
    # Count bytes AFTER the last sentinel record, not just total active size.
    def older_than_tail():
        data = log_bytes(active)
        offset = data.rfind(sentinel.encode())
        return offset >= 0 and len(data) - offset > OLD_TAIL

    for _ in range(80):
        pad()
        if older_than_tail():
            break
    require(older_than_tail(), "failures did not move beyond the old 256 KiB tail")
    require(retained(), "live API lost failures beyond the old 256 KiB tail")
    print("access-log-retention: failures retained beyond 256 KiB", flush=True)

    rotate()

    def compressed_failure_generation():
        for path in client.logs.iterdir():
            if not _GENERATION.fullmatch(path.name) or path.suffix != ".gz":
                continue
            try:
                data = log_bytes(path)
            except (OSError, EOFError, zlib.error):
                continue
            if sentinel.encode() in data and not path.with_suffix("").exists():
                return True
        return False

    wait_for(compressed_failure_generation, "Caddy did not retain a compressed failure generation")
    require(
        sentinel.encode() not in log_bytes(active),
        "rotation did not remove sentinel from active log",
    )
    wait_for(retained, "live API lost failures after native Caddy rotation")
    print("access-log-retention: failures retained after native gzip rotation", flush=True)
    print("access-log-retention: complete", flush=True)


if __name__ == "__main__":
    try:
        prove(Caddy())
    except Exception as exc:
        # Inputs, stderr and exception messages from network/filesystem parsing may
        # contain credentials or topology. Publish only our fixed assertion messages.
        detail = str(exc) if type(exc) is RuntimeError else type(exc).__name__
        print("access-log-retention: FAIL: " + detail, flush=True)
        raise SystemExit(1) from None
