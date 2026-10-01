# shellcheck shell=bash
# Opt-in backup observations. No raw inspect/configuration/log fields cross this channel.
# A caller supplies a fresh correlation token; diagnostics never alter startup's status.
backup_window_observe() {
    [[ "${PITHEAD_BACKUP_WINDOW_TOKEN:-}" =~ ^[0-9a-f]{32}$ ]] || return 0
    python3 - "$PITHEAD_BACKUP_WINDOW_TOKEN" "$1" 2>/dev/null <<'PY' || true
import datetime
import hashlib
import json
import re
import subprocess
import sys


def run(args):
    try:
        return subprocess.run(args, capture_output=True, timeout=5, check=True).stdout
    except (OSError, subprocess.SubprocessError):
        return b""


def digest(value):
    return value if isinstance(value, str) and re.fullmatch(r"sha256:[0-9a-f]{64}", value) else None


kind = sys.argv[2]
if kind not in {"backup_begin", "restart_before", "restart_succeeded", "restart_failed"}:
    sys.exit(0)
record = {"version": 1, "token": sys.argv[1], "kind": kind,
          "observed_at": datetime.datetime.now(datetime.timezone.utc).isoformat(),
          "container_id": None, "image_id": None, "health": "unknown",
          "configured_test_sha256": None, "implementation_sha256": None, "checks": []}
# Project health metadata in Docker, BEFORE transport; Output and raw control replies are absent.
fmt = ('{"container_id":{{json .Id}},"image_id":{{json .Image}},'
       '"test":{{json .Config.Healthcheck.Test}},"health":{{json .State.Health.Status}},'
       '"checks":[{{range .State.Health.Log}}{"start":{{json .Start}},'
       '"end":{{json .End}},"exit_code":{{json .ExitCode}}},{{end}}null]}')
raw = run(["docker", "inspect", "--format", fmt, "tor"])
try:
    info = json.loads(raw) if len(raw) <= 16384 else {}
except (ValueError, UnicodeError):
    info = {}
if isinstance(info, dict):
    cid = info.get("container_id")
    record["container_id"] = cid if isinstance(cid, str) and re.fullmatch(r"[0-9a-f]{64}", cid) else None
    record["image_id"] = digest(info.get("image_id"))
    if info.get("health") in {"healthy", "unhealthy", "starting"}:
        record["health"] = info["health"]
    test = info.get("test")
    if (isinstance(test, list) and 0 < len(test) <= 16
            and all(isinstance(x, str) and len(x) <= 256 for x in test)):
        record["configured_test_sha256"] = hashlib.sha256(
            json.dumps(test, separators=(",", ":")).encode()).hexdigest()
        if test == ["CMD", "/usr/local/bin/healthcheck.sh"] and record["container_id"]:
            # Sample the configured script in THIS container, not a source ancestor or tag.
            output = run(["docker", "exec", record["container_id"], "sha256sum",
                          "/usr/local/bin/healthcheck.sh"])
            match = re.fullmatch(rb"([0-9a-f]{64})  /usr/local/bin/healthcheck.sh\n", output)
            if match:
                record["implementation_sha256"] = match[1].decode()
    checks = info.get("checks")
    if isinstance(checks, list) and len(checks) <= 6:
        for check in checks:
            if not isinstance(check, dict):
                continue
            start, end, code = (check.get(k) for k in ("start", "end", "exit_code"))
            timestamp = r"[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}(?:\.[0-9]{1,9})?(?:Z|\+00:00)"
            if (isinstance(start, str) and re.fullmatch(timestamp, start)
                    and isinstance(end, str) and re.fullmatch(timestamp, end)
                    and type(code) is int and -1 <= code <= 255):
                record["checks"].append({"start": start, "end": end, "exit_code": code})
print("PITHEAD_BACKUP_OBSERVATION_V1 " + json.dumps(record, separators=(",", ":")))
PY
}
