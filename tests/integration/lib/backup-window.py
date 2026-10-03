#!/usr/bin/env python3
"""Version 1 backup-window producer and strict observation validator (stdlib only)."""

import datetime
import json
import os
import re
import secrets
import stat
import sys
from pathlib import Path

PREFIX = "PITHEAD_BACKUP_OBSERVATION_V1 "
RESULT = "PITHEAD_BACKUP_RESULT_V1 "
HEX = r"[0-9a-f]{64}"
STAMP = r"[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}(?:\.[0-9]{1,9})?(?:Z|\+00:00)"
KINDS = {"backup_begin", "restart_before", "restart_succeeded", "restart_failed"}
KEYS = {
    "version",
    "token",
    "kind",
    "observed_at",
    "container_id",
    "image_id",
    "health",
    "configured_test_sha256",
    "implementation_sha256",
    "checks",
}


def match(pattern, value):
    return isinstance(value, str) and re.fullmatch(pattern, value) is not None


def timestamp(value):
    if not match(STAMP, value):
        raise ValueError("invalid timestamp")
    whole, _, fraction = value.removesuffix("Z").removesuffix("+00:00").partition(".")
    return datetime.datetime.fromisoformat(whole), int(fraction.ljust(9, "0"))


def validate_observation(value, token):
    if not isinstance(value, dict) or set(value) != KEYS:
        raise ValueError("invalid observation fields")
    if type(value["version"]) is not int or value["version"] != 1 or value["token"] != token:
        raise ValueError("stale or unsupported observation")
    if value["kind"] not in KINDS or value["health"] not in {
        "unknown",
        "healthy",
        "unhealthy",
        "starting",
    }:
        raise ValueError("invalid observation code")
    timestamp(value["observed_at"])
    for key in ("container_id", "configured_test_sha256", "implementation_sha256", "image_id"):
        if value[key] is not None and not match(
            ("sha256:" if key == "image_id" else "") + HEX, value[key]
        ):
            raise ValueError("invalid identifier")
    checks = value["checks"]
    if not isinstance(checks, list) or len(checks) > 5:
        raise ValueError("invalid health observations")
    for check in checks:
        if not isinstance(check, dict) or set(check) != {"start", "end", "exit_code"}:
            raise ValueError("invalid health fields")
        if timestamp(check["start"]) > timestamp(check["end"]):
            raise ValueError("invalid health interval")
        if type(check["exit_code"]) is not int or not -1 <= check["exit_code"] <= 255:
            raise ValueError("invalid health exit")
    return value


def identity(lines):
    return {
        "source_commit": lines[0] if len(lines) == 3 and match(r"[0-9a-f]{40}", lines[0]) else None,
        "executable_sha256": lines[1] if len(lines) == 3 and match(HEX, lines[1]) else None,
        "checkout_clean": {"clean": True, "dirty": False}.get(lines[2])
        if len(lines) == 3
        else None,
    }


def safe_directory(directory):
    if not match(r"backup-window-[0-9a-f]{32}", directory.name):
        raise ValueError("invalid invocation directory")
    fd = os.open(directory, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)
    info = os.fstat(fd)
    if info.st_uid != os.getuid() or info.st_mode & 0o077:
        os.close(fd)
        raise ValueError("unsafe invocation directory")
    return fd


def atomic_file(directory, destination, content):
    directory_fd = safe_directory(directory)
    name = ".window-" + secrets.token_hex(16)
    try:
        fd = os.open(
            name, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600, dir_fd=directory_fd
        )
        with os.fdopen(fd, "w") as stream:
            stream.write(content)
            stream.flush()
            os.fsync(stream.fileno())
        os.replace(name, destination, src_dir_fd=directory_fd, dst_dir_fd=directory_fd)
    finally:
        try:
            os.unlink(name, dir_fd=directory_fd)
        except FileNotFoundError:
            pass
        os.close(directory_fd)


def atomic_write(directory, value):
    atomic_file(directory, "result.json", json.dumps(value, separators=(",", ":")) + "\n")


def new_result(token):
    return {
        "version": 1,
        "invocation": token,
        "attempt": "not_run",
        "outcome": "unknown",
        "observation_channel": "unavailable",
        "backup_exit_code": None,
        "reason": "not_run",
        "tor_event": "unknown",
        "canonical_product": identity([]),
        "baseline_product": identity([]),
        "observations": [],
        "execution": "unknown",
        "execution_observations": [],
        "diagnostics": {"availability": "unavailable", "artifact": None},
    }


def initialize(parent):
    parent = Path(parent)
    if not parent.is_absolute() or parent.is_symlink():
        raise ValueError("invalid output directory")
    stat = parent.stat()
    if not parent.is_dir() or stat.st_uid != os.getuid() or stat.st_mode & 0o022:
        raise ValueError("output directory is not job owned")
    token = secrets.token_hex(16)
    directory = parent / ("backup-window-" + token)
    directory.mkdir(mode=0o700)
    value = new_result(token)
    atomic_write(directory, value)
    print(directory)


def validate_result(value, directory):
    expected = {
        "version",
        "invocation",
        "attempt",
        "outcome",
        "backup_exit_code",
        "reason",
        "tor_event",
        "canonical_product",
        "baseline_product",
        "observations",
        "execution",
        "execution_observations",
        "diagnostics",
        "observation_channel",
    }
    if (
        not isinstance(value, dict)
        or set(value) != expected
        or type(value["version"]) is not int
        or value["version"] != 1
    ):
        raise ValueError("invalid result fields")
    token = value["invocation"]
    if not match(r"[0-9a-f]{32}", token) or directory.name != "backup-window-" + token:
        raise ValueError("stale invocation")
    enums = {
        "attempt": {"not_run", "attempted"},
        "outcome": {"unknown", "succeeded", "failed"},
        "reason": {"not_run", "interrupted", "command_failed", "archive_valid", "archive_invalid"},
        "tor_event": {"unknown", "tor_restart_failed"},
        "execution": {"unknown", "observed"},
        "observation_channel": {"unavailable", "available", "invalid"},
    }
    for key, allowed in enums.items():
        if not isinstance(value[key], str) or value[key] not in allowed:
            raise ValueError("invalid result code")
    code = value["backup_exit_code"]
    if code is not None and (type(code) is not int or not 0 <= code <= 255):
        raise ValueError("invalid backup exit")
    for key in ("canonical_product", "baseline_product"):
        product = value[key]
        if not isinstance(product, dict) or set(product) != {
            "source_commit",
            "executable_sha256",
            "checkout_clean",
        }:
            raise ValueError("invalid product fields")
        for field, pattern in (("source_commit", r"[0-9a-f]{40}"), ("executable_sha256", HEX)):
            if product[field] is not None and not match(pattern, product[field]):
                raise ValueError("invalid product identifier")
        if product["checkout_clean"] is not None and type(product["checkout_clean"]) is not bool:
            raise ValueError("invalid product status")
    observations = value["observations"]
    if not isinstance(observations, list) or len(observations) > 7:
        raise ValueError("oversized observations")
    for observation in observations:
        validate_observation(observation, token)
    refs = value["execution_observations"]
    if not isinstance(refs, list) or len(refs) > 35:
        raise ValueError("invalid execution references")
    for ref in refs:
        if not isinstance(ref, dict) or set(ref) != {"observation", "check"}:
            raise ValueError("invalid execution reference")
        i, j = ref["observation"], ref["check"]
        if (
            type(i) is not int
            or type(j) is not int
            or not 0 <= i < len(observations)
            or not 0 <= j < len(observations[i]["checks"])
        ):
            raise ValueError("invalid execution index")
    diagnostic = value["diagnostics"]
    if not isinstance(diagnostic, dict) or set(diagnostic) != {"availability", "artifact"}:
        raise ValueError("invalid diagnostic fields")
    if diagnostic["availability"] not in {"available", "unavailable"}:
        raise ValueError("invalid diagnostic availability")
    expected_artifact = directory.name + "/backup.log"
    if diagnostic["artifact"] is not None and diagnostic["artifact"] != expected_artifact:
        raise ValueError("unsafe artifact reference")
    if (diagnostic["availability"] == "available") != (diagnostic["artifact"] == expected_artifact):
        raise ValueError("invalid artifact availability")
    if diagnostic["availability"] == "available":
        artifact = directory / "backup.log"
        if artifact.is_symlink() or not artifact.is_file() or artifact.stat().st_uid != os.getuid():
            raise ValueError("unavailable invocation artifact")

    state = value["attempt"], value["outcome"], code, value["reason"]
    if not (
        state
        in {
            ("not_run", "unknown", None, "not_run"),
            ("attempted", "unknown", None, "interrupted"),
            ("attempted", "succeeded", 0, "archive_valid"),
            ("attempted", "failed", 0, "archive_invalid"),
        }
        or (
            state[:2] == ("attempted", "failed")
            and code is not None
            and code > 0
            and value["reason"] == "command_failed"
        )
    ):
        raise ValueError("contradictory backup outcome")
    if (value["observation_channel"] == "available") != bool(observations):
        raise ValueError("contradictory observation channel")
    if value["outcome"] == "unknown" and (
        observations or diagnostic["availability"] != "unavailable"
    ):
        raise ValueError("unsupported incomplete result")
    if (value["tor_event"], value["execution"], refs) != qualify(observations):
        raise ValueError("unsupported event or execution")


def read(directory):
    directory = Path(directory)
    directory_fd = safe_directory(directory)
    try:
        fd = os.open(
            "result.json", os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK, dir_fd=directory_fd
        )
        with os.fdopen(fd) as stream:
            info = os.fstat(stream.fileno())
            if not stat.S_ISREG(info.st_mode) or info.st_size > 65536:
                raise ValueError("unsafe result file")
            value = json.load(stream)
    finally:
        os.close(directory_fd)
    validate_result(value, directory)
    return directory, value


def finish(value, code, archive, transcript):
    if type(code) is not int or not 0 <= code <= 255:
        raise ValueError("invalid backup exit code")
    value.update(attempt="attempted", backup_exit_code=code)
    value["outcome"] = "succeeded" if code == 0 and archive else "failed"
    value["reason"] = (
        "command_failed" if code else "archive_valid" if archive else "archive_invalid"
    )
    observations = []
    rejected = False
    for line in transcript.splitlines():
        if not line.startswith(PREFIX):
            continue
        try:
            if len(line) > 8192 or len(observations) >= 7:
                raise ValueError("oversized observation")
            observations.append(
                validate_observation(json.loads(line[len(PREFIX) :]), value["invocation"])
            )
        except (ValueError, TypeError):
            rejected = True
    value["observations"] = [] if rejected else observations
    value["observation_channel"] = (
        "invalid" if rejected else "available" if observations else "unavailable"
    )
    value["tor_event"], value["execution"], value["execution_observations"] = qualify(
        value["observations"]
    )
    return value


def qualify(observations):
    event, refs = "unknown", []
    begin = None
    for index, observation in enumerate(observations):
        if observation["kind"] == "backup_begin" and begin is None:
            begin = timestamp(observation["observed_at"])
        if observation["kind"] == "restart_failed" and observation["health"] == "unhealthy":
            event = "tor_restart_failed"
        if begin is None or not all(
            observation[key] for key in ("container_id", "image_id", "configured_test_sha256")
        ):
            continue
        observed = timestamp(observation["observed_at"])
        for check_index, check in enumerate(observation["checks"]):
            if begin <= timestamp(check["start"]) <= timestamp(check["end"]) <= observed:
                refs.append({"observation": index, "check": check_index})

    return event, "observed" if refs else "unknown", refs


def main():
    action, target = sys.argv[1:3]
    if action == "init":
        initialize(target)
        return
    directory = Path(target)
    try:  # Unsafe directories are never recoverable record corruption.
        os.close(safe_directory(directory))
    except (OSError, ValueError):
        if action != "finish":
            raise
        value = new_result(directory.name.removeprefix("backup-window-"))
        finish(value, int(sys.argv[3]), sys.argv[4] == "valid", sys.stdin.read())
        validate_result(value, directory)
        print(RESULT + json.dumps(value, separators=(",", ":")), flush=True)
        return
    if action == "diagnostics":
        atomic_file(directory, "backup.log", sys.stdin.read())
        return
    try:
        directory, value = read(target)
    except (OSError, ValueError, KeyError, TypeError):
        if action != "finish":
            raise
        directory = Path(target)
        token = directory.name.removeprefix("backup-window-")
        if not match(r"[0-9a-f]{32}", token):
            raise ValueError("invalid invocation") from None
        value = new_result(token)
    if action == "attempt":
        lines = sys.stdin.read(1024).splitlines()
        if len(lines) != 6:
            lines = []
        value["canonical_product"] = identity(lines[:3])
        value["baseline_product"] = identity(lines[3:])
        value.update(attempt="attempted", reason="interrupted")
    elif action == "finish":
        # The original transcript is private; only allowlisted observations enter the result.
        transcript = sys.stdin.read()
        finish(value, int(sys.argv[3]), sys.argv[4] == "valid", transcript)
        diagnostic = directory / "backup.log"
        if diagnostic.is_file() and not diagnostic.is_symlink():
            value["diagnostics"] = {
                "availability": "available",
                "artifact": directory.name + "/backup.log",
            }
    elif action != "emit":
        raise ValueError("unsupported action")
    validate_result(value, directory)
    # The log channel survives an artifact/disk failure with the original command code.
    print(RESULT + json.dumps(value, separators=(",", ":")), flush=True)
    try:
        atomic_write(directory, value)
    except OSError:
        print("Backup-window result file unavailable.", file=sys.stderr)


if __name__ == "__main__":
    try:
        main()
    except (OSError, ValueError, KeyError, TypeError):
        # Fixed diagnostic only; never print a private path or an untrusted field.
        print("Backup-window diagnostics unavailable.", file=sys.stderr)
        sys.exit(1)
