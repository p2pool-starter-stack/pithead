"""Bounded, allowlisted evidence from the asserted node-recovery status invocation."""

import json
import os
import re
import selectors
import signal
import subprocess
import sys
import time
from pathlib import Path

LIMIT = 65536
SERVICES = ("monerod", "tari", "tor", "p2pool", "xmrig-proxy", "dashboard")
STATES = ("running", "exited", "restarting", "paused", "created", "dead", "missing")
HEALTH = ("healthy", "unhealthy", "starting", "none")


def probe(script, command, seconds=15, include_stderr=False):
    """Cap retained bytes and wall time, including SSH and inherited pipe writers."""
    start = time.monotonic()
    data = bytearray()
    total = 0
    timed_out = False
    with subprocess.Popen(  # noqa: S603 — script and commands are harness-owned, not probe output.
        ["/bin/bash", "-c", script + '\nrx "$1"', "node-recovery", command],
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT if include_stderr else subprocess.DEVNULL,
        stdin=subprocess.DEVNULL,
        start_new_session=True,
    ) as proc:
        with selectors.DefaultSelector() as selector:
            selector.register(proc.stdout, selectors.EVENT_READ)
            while selector.get_map():
                left = seconds - (time.monotonic() - start)
                if left <= 0:
                    timed_out = True
                    break
                for key, _ in selector.select(min(left, 0.2)):
                    chunk = os.read(key.fd, 8192)
                    if not chunk:
                        selector.unregister(key.fileobj)
                    else:
                        total += len(chunk)
                        data.extend(chunk[: max(0, LIMIT - len(data))])
        # A process may close stdout and then hang; the same deadline covers its exit.
        try:
            proc.wait(timeout=max(0.001, seconds - (time.monotonic() - start)))
        except subprocess.TimeoutExpired:
            timed_out = True
        if timed_out:
            try:
                os.killpg(proc.pid, signal.SIGKILL)
            except ProcessLookupError:
                pass
            proc.wait()
        rc = 124 if timed_out else proc.returncode
        if rc < 0:
            rc = 128 - rc
    return {
        "exit_code": rc,
        "timed_out": timed_out,
        "truncated": total > LIMIT,
        "bytes_observed": total,
    }, bytes(data)


def enum(value, choices):
    return value if isinstance(value, str) and value in choices else None


def obj(value):
    return value if isinstance(value, dict) else {}


def boolean(value):
    return value if type(value) is bool else None


def number(value):
    return value if type(value) is int and 0 <= value <= 10**12 else None


def status_output(raw, truncated=False):
    # Only complete service verdicts are safe to retain from status.
    if truncated:
        raw = raw.rsplit(b"\n", 1)[0] if b"\n" in raw else b""
    text = re.sub(r"\x1b\[[0-9;]*m", "", raw.decode("utf-8", "replace"))
    service = "(?:" + "|".join(SERVICES) + ")"
    verdict = (
        r"(?:running|starting \(health check pending\)|running but UNHEALTHY|"
        r"restarting \(possible crash loop — check logs\)|exited|paused|created|dead|missing)"
    )
    lines = text.splitlines()
    kept = [
        line.strip()
        for line in lines
        if re.fullmatch(r"\s*[✓⚠✗…]\s+" + service + r"\s+" + verdict + r"\s*", line)
    ]
    return {"service_verdict_lines": kept, "omitted_lines": len(lines) - len(kept)}


def dashboard(raw):
    state = json.loads(raw)
    if not isinstance(state, dict):
        raise ValueError("dashboard is not an object")
    sync = obj(state.get("sync"))
    pool = obj(state.get("pool"))
    return {
        "syncing": boolean(state.get("syncing")),
        "pool": {
            "type": enum(pool.get("type"), ("Main", "Mini", "Nano", "Unknown")),
            "syncing": boolean(pool.get("syncing")),
            "sidechain_height": number(pool.get("sidechain_height")),
        },
        "sync": {
            chain: {
                "state": enum(obj(sync.get(chain)).get("state"), ("done", "loading", "syncing")),
                "current": number(obj(sync.get(chain)).get("current")),
                "target": number(obj(sync.get(chain)).get("target")),
            }
            for chain in ("monero", "tari")
        },
        "monero_health": {
            "level": enum(
                obj(obj(state.get("monero")).get("health")).get("level"),
                ("green", "red", "unknown"),
            ),
        },
        "tari_connected": boolean(obj(state.get("tari")).get("connected")),
    }


def services(raw):
    out = {}
    for line in raw.splitlines():
        item = obj(json.loads(line))
        name = enum(item.get("service"), SERVICES)
        if name:
            out[name] = {
                "state": enum(item.get("state"), STATES),
                "health": enum(item.get("health"), HEALTH),
                "restarts": number(item.get("restarts")),
                "exit_code": number(item.get("exit_code")),
                "oom_killed": boolean(item.get("oom_killed")),
            }
    return out


def main():
    script, command, destination, wait_rc, elapsed = sys.argv[1:]
    status, raw = probe(script, command, 30, include_stderr=True)
    rc = status["exit_code"]
    # stdout carries only the original verdict, even if projection or persistence fails.
    print(rc, flush=True)
    if rc == 0:
        return 0
    status["output"] = status_output(raw, status["truncated"])
    evidence = {
        "wait_exit_code": int(wait_rc),
        "wait_elapsed_seconds": int(elapsed),
        "status": status,
    }
    commands = {
        "dashboard": "curl -fsS --max-time 10 http://127.0.0.1:8000/api/state",
        "services": "docker inspect --format "
        + '\'{"service":{{json .Name}},"state":{{json .State.Status}},'
        + '"health":{{if .State.Health}}{{json .State.Health.Status}}{{else}}"none"{{end}},'
        + '"restarts":{{.RestartCount}},"exit_code":{{.State.ExitCode}},'
        + '"oom_killed":{{.State.OOMKilled}}}\' '
        + " ".join(SERVICES),
    }
    # Docker names have one leading slash; remove it only in the typed service field.
    for kind, cmd in commands.items():
        metadata, raw = probe(script, cmd)
        try:
            if kind == "services":
                rows = [obj(json.loads(line)) for line in raw.splitlines()]
                for row in rows:
                    if isinstance(row.get("service"), str):
                        row["service"] = row["service"].removeprefix("/")
                raw = b"\n".join(json.dumps(row).encode() for row in rows)
            metadata["projection"] = (dashboard if kind == "dashboard" else services)(raw)
            projection = metadata["projection"]
            if kind == "dashboard":
                complete = (
                    projection["syncing"] is not None
                    and projection["pool"]["syncing"] is not None
                    and all(
                        projection["sync"][chain]["state"] is not None
                        for chain in ("monero", "tari")
                    )
                )
            else:
                complete = set(projection) == set(SERVICES) and all(
                    value is not None
                    for service in projection.values()
                    for value in service.values()
                )
            metadata["projection_available"] = (
                metadata["exit_code"] == 0 and not metadata["truncated"] and complete
            )
        except (ValueError, TypeError, RecursionError):
            metadata["projection_available"] = False
        evidence[kind] = metadata
    try:
        target = Path(destination)
        target.parent.mkdir(parents=True, exist_ok=True)
        with target.open("w", encoding="utf-8") as stream:
            json.dump(evidence, stream, indent=2, allow_nan=False)
            stream.write("\n")
    except OSError:
        print("node recovery evidence write failed", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
