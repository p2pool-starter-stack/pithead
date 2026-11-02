import json
import os
import re
import subprocess
import sys
from pathlib import Path

import pytest

# ruff: noqa: S101, S603, S607

ROOT = Path(__file__).resolve().parents[2]
SOURCE = ROOT / "go/internal/dashboard/network/status.go"
ORACLE = (
    "tests/service/network/test_egress_status.py::"
    "test_each_host_verdict_maps_to_a_state[0-enforced]"
)
NATIVE_ORACLES = (
    ORACLE,
    "tests/service/network/test_egress_status.py::"
    "test_a_missing_firewall_warns_even_when_every_route_is_tor",
)


def _environment(tmp_path):
    env = os.environ.copy()
    env.update(
        PITHEAD_IMPL="go",
        TZ="UTC",
        PYTHONPATH=f"{ROOT / 'tests/go-parity'}:{ROOT / 'dashboard'}",
        PYTEST_PLUGINS="",
        PYTEST_ADDOPTS="",
        PYTHONPYCACHEPREFIX=str(ROOT / ".go-cache/pycache"),
        COVERAGE_FILE=str(tmp_path / "egress-status-controls.coverage"),
    )
    return env


def _mutated_binary(tmp_path):
    text = SOURCE.read_text()
    seam = "return stateEnforced, nil"
    assert text.count(seam) == 1
    altered = tmp_path / SOURCE.name
    altered.write_text(text.replace(seam, "return stateUnverified, nil"))
    overlay = tmp_path / "overlay.json"
    overlay.write_text(json.dumps({"Replace": {str(SOURCE): str(altered)}}))
    binary = tmp_path / "dashboard"
    env = os.environ.copy()
    env.update(
        GOCACHE=str(ROOT / ".go-cache/build"),
        GOMODCACHE=str(ROOT / ".go-cache/mod"),
        GOPATH=str(ROOT / ".go-cache/gopath"),
        GOTMPDIR=str(ROOT / ".go-cache/tmp"),
        GOPROXY="off",
    )
    result = subprocess.run(
        ["go", "build", "-overlay", str(overlay), "-o", str(binary), "./cmd/dashboard"],
        cwd=ROOT / "go",
        env=env,
        capture_output=True,
        text=True,
        timeout=120,
        check=False,
    )
    assert result.returncode == 0, result.stderr
    return binary


def _pytest(arguments, env, timeout=120):
    return subprocess.run(
        [
            sys.executable,
            "-m",
            "pytest",
            "-p",
            "no:cacheprovider",
            "-p",
            "dashboard_egress_status_plugin",
            *arguments,
            "--no-cov",
        ],
        cwd=ROOT / "dashboard",
        env=env,
        capture_output=True,
        text=True,
        timeout=timeout,
        check=False,
    )


def test_source_mutation_breaks_unchanged_oracle(tmp_path):
    trace = tmp_path / "egress-status.trace"
    env = _environment(tmp_path)
    env.update(
        PITHEAD_DASHBOARD_GO_BINARY=str(_mutated_binary(tmp_path)),
        PITHEAD_EGRESS_STATUS_TRACE=str(trace),
    )
    result = _pytest([ORACLE], env)
    assert result.returncode == 1
    assert "1 failed" in result.stdout
    assert trace.read_text().splitlines() == [
        "firewall-status-valid",
        "firewall-status-result",
    ]


def test_unchanged_oracles_use_native_without_compatibility(tmp_path):
    result = _pytest(list(NATIVE_ORACLES), _environment(tmp_path))
    assert result.returncode == 0, result.stdout + result.stderr
    match = re.search(r"native egress status calls (\{[^\n]+\})", result.stdout)
    assert match
    assert json.loads(match.group(1)) == {
        "firewall-plan": 1,
        "firewall-status-result": 1,
        "firewall-status-valid": 1,
    }
    assert "intentional egress status compatibility {}" in result.stdout
    assert "unexpected egress status fallbacks {}" in result.stdout


def test_worker_process_counters_reach_controller(tmp_path):
    result = _pytest(["-n", "1", ORACLE], _environment(tmp_path))
    assert result.returncode == 0, result.stdout + result.stderr
    match = re.search(r"native egress status calls (\{[^\n]+\})", result.stdout)
    assert match
    assert json.loads(match.group(1)) == {
        "firewall-status-result": 1,
        "firewall-status-valid": 1,
    }


@pytest.mark.parametrize("implementation", [None, "bash", "python"])
def test_reference_selection_never_invokes_native_status(tmp_path, implementation):
    marker = tmp_path / "called"
    binary = tmp_path / "dashboard"
    binary.write_text('#!/bin/sh\n: > "$PITHEAD_SENTINEL_MARKER"\nexit 99\n')
    binary.chmod(0o755)
    env = _environment(tmp_path)
    env.update(
        PITHEAD_DASHBOARD_GO_BINARY=str(binary),
        PITHEAD_SENTINEL_MARKER=str(marker),
    )
    if implementation is None:
        env.pop("PITHEAD_IMPL", None)
    else:
        env["PITHEAD_IMPL"] = implementation
    result = _pytest([ORACLE], env, timeout=60)
    assert result.returncode == 0, result.stdout + result.stderr
    assert not marker.exists()
