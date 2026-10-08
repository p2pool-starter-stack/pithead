"""Check the real boot's logged capability marker and dashboard failure accounting."""

import sys
import time
from pathlib import Path


def validate(rows, summary, boot_started, now):
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
    ordinary = [
        r
        for r in rows
        if r.get("status") == 401
        and now - r.get("ts", 0) <= 86400
        and r.get("pithead_probe") != "boot-health-v1"
    ]
    if summary["failures_24h"] != len(ordinary) or summary["rotate_hint"] != (len(ordinary) >= 5):
        raise AssertionError("dashboard did not exclude only marked boot probes")


def selftest():
    probe = {
        "ts": 1000,
        "status": 401,
        "pithead_probe": "boot-health-v1",
        "request": {"method": "GET", "uri": "/.pithead-boot-health", "remote_ip": "127.0.0.1"},
    }
    quiet = {"failures_24h": 0, "rotate_hint": False}
    validate([probe], quiet, 900, 1100)
    for rows, summary, boot in [
        ([], quiet, 900),
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
        ([probe], {"failures_24h": 1, "rotate_hint": False}, 900),
    ]:
        try:
            validate(rows, summary, boot, 1100)
        except AssertionError:
            continue
        raise AssertionError("negative evidence control passed")
    print("boot-probe evidence selftest passed")


if __name__ == "__main__":
    if sys.argv[1:] == ["--self-test"]:
        selftest()
    else:
        from mining_dashboard.service import audit_service

        now = time.time()
        boot_started = now - float(Path("/proc/uptime").read_text().split()[0])
        rows = audit_service._tail_json_lines(audit_service.config.ACCESS_LOG_PATH)
        if rows is None:
            raise AssertionError("Caddy access log is unavailable")
        validate(rows, audit_service.access_summary(now=now), boot_started, now)
