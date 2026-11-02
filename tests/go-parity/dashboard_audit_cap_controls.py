import json
import os
import re
import subprocess
import sys
from pathlib import Path

import pytest

# ruff: noqa: S101, S603, S607

ROOT = Path(__file__).resolve().parents[2]
SOURCE = ROOT / "go/internal/dashboard/network/audit_cap.go"
NAMES_ORACLE = (
    "tests/service/workers/test_worker_name_space_cap.py::"
    "TestTheNameSpaceIsBounded::test_a_rotating_device_is_bounded_to_the_ceiling"
)
SPEND_ORACLE = (
    "tests/service/test_data_service_rig_edit_detection.py::"
    "TestRigEditDetection::test_distinct_change_id_flood_is_bounded_per_worker"
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
        COVERAGE_FILE=str(tmp_path / "audit-cap-controls.coverage"),
    )
    return env


def _mutated_binary(tmp_path, seam, replacement):
    text = SOURCE.read_text()
    assert text.count(seam) == 1
    altered = tmp_path / SOURCE.name
    altered.write_text(text.replace(seam, replacement))
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


def _pytest(arguments, env):
    return subprocess.run(
        [
            sys.executable,
            "-m",
            "pytest",
            "-p",
            "no:cacheprovider",
            "-p",
            "dashboard_audit_cap_plugin",
            *arguments,
            "--no-cov",
        ],
        cwd=ROOT / "dashboard",
        env=env,
        capture_output=True,
        text=True,
        timeout=120,
        check=False,
    )


@pytest.mark.parametrize(
    ("oracle", "seam", "replacement"),
    [
        (
            NAMES_ORACLE,
            "namesFull[count] = count >= *request.Limit",
            "namesFull[count] = count < *request.Limit",
        ),
        (
            SPEND_ORACLE,
            "spend[count] = [2]bool{count < *request.Limit, count == *request.Limit}",
            "spend[count] = [2]bool{count >= *request.Limit, count != *request.Limit}",
        ),
    ],
)
def test_source_mutation_breaks_unchanged_oracle(tmp_path, oracle, seam, replacement):
    env = _environment(tmp_path)
    env["PITHEAD_DASHBOARD_GO_BINARY"] = str(_mutated_binary(tmp_path, seam, replacement))
    result = _pytest([oracle], env)
    assert result.returncode == 1
    assert "1 failed" in result.stdout


def test_unchanged_oracle_reaches_native_policy_without_fallback(tmp_path):
    env = _environment(tmp_path)
    env["PITHEAD_DASHBOARD_GO_BINARY"] = str(ROOT / "go/bin/dashboard")
    result = _pytest([NAMES_ORACLE, SPEND_ORACLE, "-n", "1"], env)
    output = result.stdout + result.stderr
    assert result.returncode == 0, output
    assert re.search(r'native audit cap plan calls \{"audit-cap-policy": [1-9][0-9]*\}', output)
    assert re.search(r'native audit cap selections .*"_names_full": [1-9][0-9]*', output)
    assert re.search(r'native audit cap selections .*"_count_policy": [1-9][0-9]*', output)
    assert "unexpected audit cap fallbacks {}" in output
    assert "intentional audit cap compatibility {}" in output


@pytest.mark.parametrize("implementation", [None, "bash", "python"])
def test_reference_selection_never_invokes_native_policy(tmp_path, implementation):
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
    result = _pytest([NAMES_ORACLE], env)
    assert result.returncode == 0, result.stdout + result.stderr
    assert not marker.exists()
