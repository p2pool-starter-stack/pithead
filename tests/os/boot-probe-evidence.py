"""Check the real boot's logged capability marker and dashboard failure accounting."""

import gzip
import json
import sys
import time
import urllib.request
from pathlib import Path


def validate(rows, summary, boot_started, now, expected_failures=0):
    probes = [r for r in rows if r.get("pithead_probe") == "boot-health-v1"]
    if not any(boot_started <= r.get("ts", 0) <= now for r in probes):
        raise AssertionError("no marked health probe from this boot")
    for row in probes:
        request = row.get("request", {})
        if (
            row.get("status") != 401
            or request.get("method") != "GET"
            or request.get("uri") != "/.pithead-boot-health"
            or request.get("remote_ip") not in {"127.0.0.1", "::1"}
            or row.get("user_id", "") != ""
        ):
            raise AssertionError("marked row is not the exact locked boot probe")
    for row in rows:
        if any(
            k.lower() == "x-pithead-boot-probe" for k in row.get("request", {}).get("headers", {})
        ):
            raise AssertionError("boot capability header was retained in the access log")
    if not summary.get("available", False):
        raise AssertionError("access summary is unavailable")
    ordinary = [
        r
        for r in rows
        if r.get("status") == 401
        and 0 <= now - r.get("ts", 0) <= 86400
        and r.get("pithead_probe") != "boot-health-v1"
    ]
    if len(ordinary) != expected_failures:
        raise AssertionError("ordinary failure count differs from the controlled test window")
    if summary["failures_24h"] != len(ordinary) or summary["rotate_hint"] != (len(ordinary) >= 5):
        raise AssertionError("dashboard did not exclude only marked boot probes")


def start_log_window(directory):
    """Archive the guest's complete log directory before reboot; preserve open writers."""
    directory = Path(directory)
    archive = directory.with_name(directory.name + ".before-reboot")
    if archive.exists():
        raise FileExistsError("pre-reboot log archive already exists")
    directory.rename(archive)
    try:
        directory.mkdir(mode=0o755)
    except OSError:
        if not directory.exists():
            archive.rename(directory)
        raise


def log_storage(path):
    """Inspect at most three native log files, 64 KiB each; retain only counts."""
    path = Path(path)
    result = {"files": 0, "bytes_sampled": 0, "nul_bytes": 0, "invalid_lines": 0, "health_rows": 0}
    candidates = [path, *sorted(path.parent.glob("access-*.log*"))[-2:]]
    for candidate in candidates:
        try:
            opener = gzip.open if candidate.suffix == ".gz" else open
            with opener(candidate, "rb") as stream:
                raw = stream.read(65536)
        except (OSError, EOFError):
            continue
        result["files"] += 1
        result["bytes_sampled"] += len(raw)
        result["nul_bytes"] += raw.count(b"\0")
        for line in raw.splitlines():
            if not line:
                continue
            try:
                row = json.loads(line)
            except (ValueError, UnicodeError):
                result["invalid_lines"] += 1
                continue
            if isinstance(row, dict) and isinstance(row.get("request"), dict):
                result["health_rows"] += row["request"].get("uri") == "/.pithead-boot-health"
    return result


def caddy_configuration():
    """Read host-network admin config without emitting any credentials or topology."""
    result = {"available": False, "boot_matcher": False, "log_destination": False}
    try:
        opener = urllib.request.build_opener(urllib.request.ProxyHandler({}))
        with opener.open("http://127.0.0.1:2019/config/", timeout=3) as response:
            config = json.loads(response.read(1048576))
        serialized = json.dumps(config)
        result.update(
            available=True,
            boot_matcher="X-Pithead-Boot-Probe" in serialized and "pithead_probe" in serialized,
            log_destination="/var/log/caddy/access.log" in serialized,
        )
    except (OSError, ValueError):
        pass
    return result


def report(rows, summary, boot_started, now, expected_failures):
    """Bounded diagnostics: counts and context flags, never request/header/user values."""
    rows = rows or []
    probes = [r for r in rows if r.get("pithead_probe") == "boot-health-v1"]
    ordinary = [r for r in rows if r.get("status") == 401 and r not in probes]
    return {
        "expected_failures": expected_failures,
        "rows": len(rows),
        "marked_probes": len(probes),
        "current_boot_probes": sum(boot_started <= r.get("ts", 0) <= now for r in probes),
        "marked_non_401": sum(r.get("status") != 401 for r in probes),
        "marked_wrong_method": sum(r.get("request", {}).get("method") != "GET" for r in probes),
        "marked_wrong_uri": sum(
            r.get("request", {}).get("uri") != "/.pithead-boot-health" for r in probes
        ),
        "marked_non_loopback": sum(
            r.get("request", {}).get("remote_ip") not in {"127.0.0.1", "::1"} for r in probes
        ),
        "marked_nonempty_user": sum(r.get("user_id", "") != "" for r in probes),
        "unmarked_401": len(ordinary),
        "unmarked_loopback_401": sum(
            r.get("request", {}).get("remote_ip") in {"127.0.0.1", "::1"} for r in ordinary
        ),
        "capability_header_rows": sum(
            any(
                k.lower() == "x-pithead-boot-probe" for k in r.get("request", {}).get("headers", {})
            )
            for r in rows
        ),
        "summary_available": summary.get("available") is True,
        "summary_failures": summary.get("failures_24h")
        if type(summary.get("failures_24h")) is int
        else None,
    }


def selftest():
    probe = {
        "ts": 1000,
        "status": 401,
        "pithead_probe": "boot-health-v1",
        "request": {"method": "GET", "uri": "/.pithead-boot-health", "remote_ip": "127.0.0.1"},
    }
    quiet = {"available": True, "failures_24h": 0, "rotate_hint": False}
    validate([probe], quiet, 900, 1100)
    wrong = {"ts": 1050, "status": 401, "request": {"method": "GET", "uri": "/"}}
    validate(
        [probe, wrong], {"available": True, "failures_24h": 1, "rotate_hint": False}, 900, 1100, 1
    )
    for rows, count in [([probe], 1), ([probe, wrong], 0)]:
        try:
            validate(
                rows, {"available": True, "failures_24h": 0, "rotate_hint": False}, 900, 1100, count
            )
        except AssertionError:
            continue
        raise AssertionError("zero/one window control passed")
    for rows, summary, boot in [
        ([], quiet, 900),
        ([probe], {**quiet, "available": False}, 900),
        ([probe], {k: v for k, v in quiet.items() if k != "available"}, 900),
        ([probe], quiet, 1001),
        ([{**probe, "status": 200}], quiet, 900),
        ([{**probe, "request": {**probe["request"], "uri": "/"}}], quiet, 900),
        (
            [
                {
                    **probe,
                    "request": {
                        **probe["request"],
                        "headers": {"X-Pithead-Boot-Probe": ["secret"]},
                    },
                }
            ],
            quiet,
            900,
        ),
        ([probe], {"available": True, "failures_24h": 1, "rotate_hint": False}, 900),
    ]:
        try:
            validate(rows, summary, boot, 1100)
        except AssertionError:
            continue
        raise AssertionError("negative evidence control passed")
    # A malformed context is described without publishing its raw values.
    fixture_value = "private-request-value"
    dirty = {
        **probe,
        "user_id": fixture_value,
        "request": {
            "method": fixture_value,
            "uri": fixture_value,
            "remote_ip": fixture_value,
            "headers": {"X-Pithead-Boot-Probe": [fixture_value]},
        },
    }
    observed = report([dirty, wrong], quiet, 900, 1100, 1)
    expected_values = {
        "current_boot_probes": 1,
        "marked_wrong_method": 1,
        "marked_wrong_uri": 1,
        "marked_non_loopback": 1,
        "marked_nonempty_user": 1,
        "capability_header_rows": 1,
        "unmarked_401": 1,
        "summary_failures": 0,
    }
    if any(observed[k] != v for k, v in expected_values.items()):
        raise AssertionError("diagnostic counts did not identify the failed context")
    if fixture_value in json.dumps(observed):
        raise AssertionError("diagnostic leaked a private request value")
    if report(None, {}, 900, 1100, 0)["summary_available"]:
        raise AssertionError("diagnostic accepted an unavailable summary")
    # Exercise the real entry point with the SSH stderr sink absent: failures must
    # remain on stdout even before the caller's remote 2>&1 forwarding.
    import io
    import runpy
    from contextlib import redirect_stdout
    from types import SimpleNamespace
    from unittest.mock import patch

    fake = SimpleNamespace(
        config=SimpleNamespace(ACCESS_LOG_PATH="unused-fixture"),
        access_rows=lambda _path: [dirty],
        access_summary=lambda **_kwargs: quiet,
    )
    captured = io.StringIO()
    with (
        patch.dict(sys.modules, {"mining_dashboard.service": SimpleNamespace(audit_service=fake)}),
        patch.object(sys, "argv", [__file__, "0"]),
        patch("time.time", return_value=1100),
        patch("time.sleep"),
        patch("urllib.request.build_opener", side_effect=OSError("fixture unavailable")),
        patch.object(Path, "read_text", return_value="200"),
        redirect_stdout(captured),
    ):
        try:
            runpy.run_path(__file__, run_name="__main__")
        except AssertionError:
            pass
        else:
            raise AssertionError("live evidence entry point accepted a malformed probe")
    output = captured.getvalue()
    if "marked row is not the exact locked boot probe" not in output:
        raise AssertionError("live evidence entry point lost its assertion reason")
    if json.loads(output.splitlines()[-1])["marked_wrong_uri"] != 1 or fixture_value in output:
        raise AssertionError("live evidence entry point lost or leaked its diagnostic")
    with patch("urllib.request.build_opener") as factory:
        factory.return_value.open.return_value = io.BytesIO(
            json.dumps(
                {
                    "matcher": "X-Pithead-Boot-Probe",
                    "field": "pithead_probe",
                    "filename": "/var/log/caddy/access.log",
                    "credential": fixture_value,
                }
            ).encode()
        )
        configuration = caddy_configuration()
        if not all(configuration.values()) or fixture_value in json.dumps(configuration):
            raise AssertionError("configuration diagnostic lost flags or leaked a credential")
    import os
    from tempfile import TemporaryDirectory

    with TemporaryDirectory(dir=os.environ.get("TMPDIR")) as directory:
        logfile = Path(directory) / "access.log"
        logfile.write_bytes(b"\0" + json.dumps(probe).encode() + b"\n")
        rolled = Path(directory) / "access-previous.log.gz"
        with gzip.open(rolled, "wb") as stream:
            stream.write(json.dumps(probe).encode() + b"\n")
        storage = log_storage(logfile)
        if storage["files"] != 2 or storage["nul_bytes"] != 1:
            raise AssertionError("storage diagnostic lost current/rolled data")
        if storage["invalid_lines"] != 1 or storage["health_rows"] != 1:
            raise AssertionError("storage diagnostic hid malformed or rolled boot evidence")
    with TemporaryDirectory(dir=os.environ.get("TMPDIR")) as directory:
        logs = Path(directory) / "logs"
        logs.mkdir()
        active = logs / "access.log"
        active.write_bytes(b"old-active\n")
        (logs / "access-previous.log.gz").write_bytes(b"old-generation")
        with active.open("ab") as old_writer:
            start_log_window(logs)
            old_writer.write(b"late-old-write\n")
        archive = logs.with_name("logs.before-reboot")
        if list(logs.iterdir()) or not (archive / "access-previous.log.gz").exists():
            raise AssertionError("log window retained pre-boot generations or lost their archive")
        if (archive / "access.log").read_bytes() != b"old-active\nlate-old-write\n":
            raise AssertionError("log window lost an open writer's previous records")
        try:
            start_log_window(logs)
        except FileExistsError:
            pass
        else:
            raise AssertionError("log window overwrote the previous archive")
    print("boot-probe evidence selftest passed")


if __name__ == "__main__":
    if sys.argv[1:] == ["--self-test"]:
        selftest()
    elif len(sys.argv) == 3 and sys.argv[1] == "--start-window":
        start_log_window(sys.argv[2])
    else:
        from mining_dashboard.service import audit_service

        expected = int(sys.argv[1])
        if expected not in {0, 1}:
            raise ValueError("expected failure count must be zero or one")
        for attempt in range(50):
            now = time.time()
            boot_started = now - float(Path("/proc/uptime").read_text().split()[0])
            rows = audit_service.access_rows(audit_service.config.ACCESS_LOG_PATH)
            summary = audit_service.access_summary(now=now)
            try:
                if rows is None:
                    raise AssertionError("Caddy access log is unavailable")
                validate(rows, summary, boot_started, now, expected)
                print(
                    json.dumps(
                        {
                            **report(rows, summary, boot_started, now, expected),
                            "storage": log_storage(audit_service.config.ACCESS_LOG_PATH),
                            "caddy": caddy_configuration(),
                        },
                        sort_keys=True,
                    )
                )
                break
            except AssertionError as failure:
                if attempt == 49:
                    print(str(failure), flush=True)
                    print(
                        json.dumps(
                            {
                                **report(rows, summary, boot_started, now, expected),
                                "storage": log_storage(audit_service.config.ACCESS_LOG_PATH),
                                "caddy": caddy_configuration(),
                            },
                            sort_keys=True,
                        ),
                        flush=True,
                    )
                    raise
                time.sleep(0.1)
