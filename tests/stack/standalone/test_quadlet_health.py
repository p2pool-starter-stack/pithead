import json
import re
import shlex
import subprocess
import sys
import tempfile
from pathlib import Path


def require(condition, message):
    if not condition:
        raise AssertionError(message)


def check(unit, compose):
    service = re.search(r"^  xmrig-proxy:\n(.*?)(?=^  [\w-]+:|\Z)", compose, re.M | re.S)
    require(service, "Compose proxy service is missing")
    health = re.search(r"^    healthcheck:\n(.*?)(?=^    \w|\Z)", service[1], re.M | re.S)
    require(health, "Compose proxy healthcheck is missing")
    test = re.search(r"^      test: (.+)$", health[1], re.M)
    require(test, "Compose proxy health command is missing")
    kind, command = json.loads(test[1])
    require(kind == "CMD-SHELL", "Quadlet health assertion failed")
    values = {}
    for line in unit.splitlines():
        if "=" in line:
            key, value = line.split("=", 1)
            values.setdefault(key, []).append(value)
    require(
        values.get("HealthCmd") == [f"/bin/sh -c '{command}'"],
        "Quadlet health command differs from Compose",
    )
    for compose_key, quadlet_key in (
        ("interval", "HealthInterval"),
        ("timeout", "HealthTimeout"),
        ("retries", "HealthRetries"),
        ("start_period", "HealthStartPeriod"),
    ):
        value = re.search(rf"^      {compose_key}: (.+)$", health[1], re.M)
        require(value, f"Compose {compose_key} is missing")
        require(
            values.get(quadlet_key) == [value[1]], f"Quadlet {quadlet_key} differs from Compose"
        )
    require(values.get("Notify") == ["healthy"], "Quadlet health assertion failed")
    require(values.get("TimeoutStartSec") == ["infinity"], "Quadlet health assertion failed")
    script = "/usr/local/bin/xmrig-proxy-healthcheck.sh"
    require(
        command == f"[ -x {script} ] && exec {script} || exit 0", "Quadlet health assertion failed"
    )
    with tempfile.TemporaryDirectory() as temporary:
        probe = Path(temporary) / "probe.sh"
        argv = shlex.split(values["HealthCmd"][0])
        shell_command = argv[2].replace(script, shlex.quote(str(probe)))
        for state, expected in (
            ("absent", 0),
            ("nonexecutable", 0),
            ("success", 0),
            ("failure", 1),
        ):
            if state != "absent":
                probe.write_text("#!/bin/sh\nexit " + ("1" if state == "failure" else "0") + "\n")
                probe.chmod(0o600 if state == "nonexecutable" else 0o700)
            result = subprocess.run(  # noqa: S603
                ["/bin/sh", "-c", shell_command], capture_output=True, timeout=5
            )
            require(
                result.returncode == expected,
                f"{state}: expected {expected}, got {result.returncode}",
            )
    print("PASS: Quadlet proxy health parity, startup notification and four guard cases")


if __name__ == "__main__":
    check(Path(sys.argv[1]).read_text(), Path(sys.argv[2]).read_text())
