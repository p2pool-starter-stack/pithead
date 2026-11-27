#!/usr/bin/env python3
"""Read-only, allowlisted Caddy failure snapshot, streamed to the KVM guest."""

import json
import os
import re
import selectors
import subprocess
import time
from pathlib import Path

DIRECTIVES = frozenset(
    "auto_https bind basic_auth tls reverse_proxy header_up log output format redir".split()
)
ERRORS = (
    "cannot assign requested address",
    "address already in use",
    "permission denied",
    "no such file or directory",
    "unrecognized directive",
    "wrong argument count",
    "unexpected token",
    "loading initial config",
    "adapting config using caddyfile",
    "certificate",
    "private key",
)


def config_shape(text):
    """Keep line numbers and directives; never emit operands or auth entries."""
    rows = []
    for number, line in enumerate(text.splitlines()[:200], 1):
        words = line.split()
        if not words or words[0].startswith("#"):
            continue
        directive = words[0] if words[0] in DIRECTIVES else "value"
        if words == ["{"] or words == ["}"]:
            directive = words[0]
        rows.append({"line": number, "directive": directive, "tokens": len(words)})
    return {"lines": rows, "truncated": len(text.splitlines()) > 200}


def log_shape(text):
    """Retain daemon error phrases, never arbitrary strings from its config."""
    rows = []
    for line in text.splitlines()[-40:]:
        try:
            entry = json.loads(line)
        except ValueError:
            entry = None
        if isinstance(entry, dict):
            message = " ".join(str(entry.get(key, "")) for key in ("msg", "error"))
            level = entry.get("level")
            if level not in ("debug", "info", "warn", "error", "fatal", "panic"):
                level = "unknown"
        else:
            message, level = line, "unknown"
        lower = message.lower()
        location = re.search(r"Caddyfile:(\d{1,6})(?:\D|$)", message)
        rows.append(
            {
                "level": level,
                "phrases": [phrase for phrase in ERRORS if phrase in lower],
                "config_line": int(location[1]) if location else None,
                "bytes": len(line.encode()),
            }
        )
    return rows


def state_shape(text):
    try:
        state = json.loads(text)
    except ValueError:
        return {"available": False}
    if not isinstance(state, dict):
        return {"available": False}
    result = {"available": True}
    for key in ("Running", "Restarting", "OOMKilled"):
        if type(state.get(key)) is bool:
            result[key] = state[key]
    if type(state.get("ExitCode")) is int:
        result["ExitCode"] = state["ExitCode"]
    status = state.get("Status")
    if status in ("running", "exited", "restarting", "created", "paused", "dead"):
        result["Status"] = status
    return result


COMMANDS = {
    "state": ["/usr/bin/podman", "inspect", "caddy", "--format", "{{json .State}}"],
    "log": ["/usr/bin/podman", "logs", "--tail", "40", "caddy"],
}


def probe(kind, seconds=4):
    """Bound ingestion as well as output; terminate and reap a capped/timed-out probe."""
    try:
        process = subprocess.Popen(  # noqa: S603 -- argv comes only from the fixed probe table
            COMMANDS[kind], stdout=subprocess.PIPE, stderr=subprocess.STDOUT
        )
    except OSError:
        return 127, "", False
    data = bytearray()
    deadline = time.monotonic() + seconds
    rc = None
    truncated = False
    try:
        with selectors.DefaultSelector() as selector:
            selector.register(process.stdout, selectors.EVENT_READ)
            while True:
                remaining = deadline - time.monotonic()
                if remaining <= 0 or not selector.select(remaining):
                    rc = 124
                    break
                chunk = os.read(process.stdout.fileno(), min(4096, 65537 - len(data)))
                if not chunk:
                    try:
                        rc = process.wait(timeout=max(0.001, deadline - time.monotonic()))
                    except subprocess.TimeoutExpired:
                        rc = 124
                    break
                data.extend(chunk)
                if len(data) > 65536:
                    truncated = True
                    break
    finally:
        if process.poll() is None:
            process.kill()
        actual_rc = process.wait()
        process.stdout.close()
    return rc if rc is not None else actual_rc, data[:65536].decode(errors="replace"), truncated


def snapshot():
    state_rc, state, state_truncated = probe("state")
    # Caddy writes startup errors to stderr; merge both Podman streams before classifying.
    log_rc, log, log_truncated = probe("log")
    try:
        with Path("/data/pithead/Caddyfile").open("rb") as stream:
            config = stream.read(65537)
        shape = config_shape(config[:65536].decode(errors="replace"))
        shape["truncated"] |= len(config) > 65536
        shape["available"] = True
    except OSError:
        shape = {"available": False}
    return {
        "state_exit": state_rc,
        "state_truncated": state_truncated,
        "state": state_shape(state),
        "log_exit": log_rc,
        "log_truncated": log_truncated,
        "log": log_shape(log),
        "config": shape,
    }


if __name__ == "__main__":
    print(json.dumps(snapshot(), separators=(",", ":")))
