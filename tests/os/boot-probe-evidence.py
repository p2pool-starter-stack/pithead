"""Check the real boot's logged capability marker and dashboard failure accounting."""

import json
import sys
import time
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
        and now - r.get("ts", 0) <= 86400
        and r.get("pithead_probe") != "boot-health-v1"
    ]
    if len(ordinary) != expected_failures:
        raise AssertionError("ordinary failure count differs from the controlled test window")
    if summary["failures_24h"] != len(ordinary) or summary["rotate_hint"] != (len(ordinary) >= 5):
        raise AssertionError("dashboard did not exclude only marked boot probes")


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
        _tail_json_lines=lambda _path: [dirty],
        access_summary=lambda **_kwargs: quiet,
    )
    captured = io.StringIO()
    with (
        patch.dict(sys.modules, {"mining_dashboard.service": SimpleNamespace(audit_service=fake)}),
        patch.object(sys, "argv", [__file__, "0"]),
        patch("time.time", return_value=1100),
        patch("time.sleep"),
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
    print("boot-probe evidence selftest passed")


if __name__ == "__main__":
    if sys.argv[1:] == ["--self-test"]:
        selftest()
    else:
        from mining_dashboard.service import audit_service

        expected = int(sys.argv[1])
        if expected not in {0, 1}:
            raise ValueError("expected failure count must be zero or one")
        for attempt in range(50):
            now = time.time()
            boot_started = now - float(Path("/proc/uptime").read_text().split()[0])
            rows = audit_service._tail_json_lines(audit_service.config.ACCESS_LOG_PATH)
            summary = audit_service.access_summary(now=now)
            try:
                if rows is None:
                    raise AssertionError("Caddy access log is unavailable")
                validate(rows, summary, boot_started, now, expected)
                print(
                    json.dumps(report(rows, summary, boot_started, now, expected), sort_keys=True)
                )
                break
            except AssertionError as failure:
                if attempt == 49:
                    print(str(failure), flush=True)
                    print(
                        json.dumps(
                            report(rows, summary, boot_started, now, expected), sort_keys=True
                        ),
                        flush=True,
                    )
                    raise
                time.sleep(0.1)
