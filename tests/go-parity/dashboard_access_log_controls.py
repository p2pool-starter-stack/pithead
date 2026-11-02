import json
import os
import re
import subprocess
import sys
from pathlib import Path

import pytest

# ruff: noqa: S101, S603, S607

ROOT = Path(__file__).resolve().parents[2]
SOURCE = ROOT / "go/internal/dashboard/wizard/access_log.go"
ORACLE = "tests/service/test_audit_service.py::TestAccessSummary::test_rotate_hint_at_threshold"
NATIVE_ORACLES = (
    "tests/service/test_audit_service.py::TestAccessSummary::test_missing_file_reports_unavailable",
    "tests/service/test_audit_service.py::TestAccessSummary::test_counts_401s_inside_24h_only",
    ORACLE,
)


def _mutated_binary(tmp_path):
    text = SOURCE.read_text()
    seam = "comparable && comparison >= 0"
    assert text.count(seam) == 1
    altered = tmp_path / SOURCE.name
    altered.write_text(text.replace(seam, "comparable && comparison > 0"))
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


def _environment(tmp_path):
    env = os.environ.copy()
    env.update(
        PITHEAD_IMPL="go",
        TZ="UTC",
        PYTHONPATH=f"{ROOT / 'tests/go-parity'}:{ROOT / 'dashboard'}",
        PYTEST_PLUGINS="",
        PYTEST_ADDOPTS="",
        PYTHONPYCACHEPREFIX=str(ROOT / ".go-cache/pycache"),
        COVERAGE_FILE=str(tmp_path / "controls.coverage"),
    )
    return env


def test_source_mutation_breaks_unchanged_rotate_hint_oracle(tmp_path):
    binary = _mutated_binary(tmp_path)
    trace = tmp_path / "native.trace"
    env = _environment(tmp_path)
    env.update(
        PITHEAD_DASHBOARD_GO_BINARY=str(binary),
        PITHEAD_ACCESS_LOG_TRACE=str(trace),
    )
    result = subprocess.run(
        [
            sys.executable,
            "-m",
            "pytest",
            "-p",
            "no:cacheprovider",
            "-p",
            "dashboard_access_log_plugin",
            ORACLE,
            "--no-cov",
        ],
        cwd=ROOT / "dashboard",
        env=env,
        capture_output=True,
        text=True,
        timeout=120,
        check=False,
    )
    assert result.returncode == 1
    assert "1 failed" in result.stdout
    assert trace.read_text().splitlines() == ["audit-access"]


def test_worker_process_native_counters_reach_controller(tmp_path):
    result = subprocess.run(
        [
            sys.executable,
            "-m",
            "pytest",
            "-p",
            "no:cacheprovider",
            "-p",
            "dashboard_access_log_plugin",
            "-n",
            "1",
            ORACLE,
            "--no-cov",
        ],
        cwd=ROOT / "dashboard",
        env=_environment(tmp_path),
        capture_output=True,
        text=True,
        timeout=120,
        check=False,
    )
    assert result.returncode == 0, result.stdout + result.stderr
    match = re.search(r"native access log calls (\{[^\n]+\})", result.stdout)
    assert match
    assert json.loads(match.group(1)) == {"audit-access": 1}
    assert "unexpected access log fallbacks {}" in result.stdout


def test_normal_unchanged_oracles_stay_on_native_policy(tmp_path):
    result = subprocess.run(
        [
            sys.executable,
            "-m",
            "pytest",
            "-p",
            "no:cacheprovider",
            "-p",
            "dashboard_access_log_plugin",
            *NATIVE_ORACLES,
            "--no-cov",
        ],
        cwd=ROOT / "dashboard",
        env=_environment(tmp_path),
        capture_output=True,
        text=True,
        timeout=120,
        check=False,
    )
    assert result.returncode == 0, result.stdout + result.stderr
    match = re.search(r"native access log calls (\{[^\n]+\})", result.stdout)
    assert match
    assert json.loads(match.group(1)) == {"audit-access": 3}
    assert "intentional access log compatibility {}" in result.stdout
    assert "unexpected access log fallbacks {}" in result.stdout


@pytest.mark.parametrize("implementation", [None, "bash", "python"])
def test_reference_selection_never_invokes_native_access_log(tmp_path, implementation):
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
    result = subprocess.run(
        [
            sys.executable,
            "-m",
            "pytest",
            "-p",
            "no:cacheprovider",
            "-p",
            "dashboard_access_log_plugin",
            ORACLE,
            "--no-cov",
        ],
        cwd=ROOT / "dashboard",
        env=env,
        capture_output=True,
        text=True,
        timeout=60,
        check=False,
    )
    assert result.returncode == 0, result.stdout + result.stderr
    assert not marker.exists()
