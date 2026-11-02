import json
import os
import subprocess
import sys
from pathlib import Path

import pytest

# ruff: noqa: S101, S603, S607

ROOT = Path(__file__).resolve().parents[2]
DRIFT_SOURCE = ROOT / "go/internal/dashboard/fleet/detail_drift.go"
DETAIL_SOURCE = ROOT / "go/internal/dashboard/fleet/detail.go"


def mutated_binary(tmp_path, source, seam, replacement):
    text = source.read_text()
    assert text.count(seam) == 1
    altered = tmp_path / source.name
    altered.write_text(text.replace(seam, replacement))
    overlay = tmp_path / "overlay.json"
    overlay.write_text(json.dumps({"Replace": {str(source): str(altered)}}))
    binary = tmp_path / "dashboard"
    env = os.environ.copy()
    env.update(
        GOCACHE=str(ROOT / ".go-cache/build"),
        GOMODCACHE=str(ROOT / ".go-cache/mod"),
        GOPATH=str(ROOT / ".go-cache/gopath"),
        GOTMPDIR=str(ROOT / ".go-cache/tmp"),
        GOPROXY="off",
    )
    built = subprocess.run(
        ["go", "build", "-overlay", str(overlay), "-o", str(binary), "./cmd/dashboard"],
        cwd=ROOT / "go",
        env=env,
        capture_output=True,
        text=True,
        timeout=120,
        check=False,
    )
    assert built.returncode == 0, built.stderr
    return binary


def run_oracle(tmp_path, binary, test):
    trace = tmp_path / "native.trace"
    env = os.environ.copy()
    env.update(
        PITHEAD_IMPL="go",
        TZ="UTC",
        PITHEAD_DASHBOARD_GO_BINARY=str(binary),
        PITHEAD_WORKER_DETAIL_TRACE=str(trace),
        PYTHONPATH=f"{ROOT / 'tests/go-parity'}:{ROOT / 'dashboard'}",
        PYTEST_PLUGINS="",
        PYTEST_ADDOPTS="",
        PYTHONPYCACHEPREFIX=str(ROOT / ".go-cache/pycache"),
        COVERAGE_FILE=str(tmp_path / "mutation.coverage"),
    )
    result = subprocess.run(
        [
            sys.executable,
            "-m",
            "pytest",
            "-p",
            "no:cacheprovider",
            "-p",
            "dashboard_worker_detail_plugin",
            test,
            "--no-cov",
        ],
        cwd=ROOT,
        env=env,
        capture_output=True,
        text=True,
        timeout=120,
        check=False,
    )
    return result, trace


def test_source_mutation_breaks_native_drift_oracle(tmp_path):
    binary = mutated_binary(
        tmp_path,
        DRIFT_SOURCE,
        "if !comparableEqual(comparable(key, applied), comparable(key, rig)) {",
        "if false && !comparableEqual(comparable(key, applied), comparable(key, rig)) {",
    )
    result, trace = run_oracle(
        tmp_path,
        binary,
        "tests/go-parity/dashboard_worker_detail_compare.py::"
        "test_config_drift_canonicalizes_types_and_strips_credentials",
    )
    assert result.returncode == 1
    assert "1 failed" in result.stdout
    assert trace.read_text().splitlines() == ["config_drift"]


def test_disabled_native_detail_breaks_http_ownership(tmp_path):
    binary = mutated_binary(
        tmp_path,
        DETAIL_SOURCE,
        "return result, nil\n}\n\nfunc detailRows",
        'return nil, errors.New("source mutation")\n}\n\nfunc detailRows',
    )
    result, trace = run_oracle(
        tmp_path,
        binary,
        "tests/go-parity/dashboard_worker_detail_compare.py::test_http_worker_owns_detail_body",
    )
    assert result.returncode == 1
    assert "1 failed" in result.stdout
    assert "assert 500 == 200" in result.stdout
    assert trace.read_text().splitlines() == ["build_worker_detail:error"]


@pytest.mark.parametrize("implementation", [None, "bash", "python"])
def test_reference_selection_never_invokes_native_detail_helper(tmp_path, implementation):
    marker = tmp_path / "called"
    binary = tmp_path / "dashboard"
    binary.write_text('#!/bin/sh\n: > "$PITHEAD_SENTINEL_MARKER"\nexit 99\n')
    binary.chmod(0o755)
    env = os.environ.copy()
    env.update(
        PITHEAD_DASHBOARD_GO_BINARY=str(binary),
        PITHEAD_SENTINEL_MARKER=str(marker),
        PYTHONPATH=f"{ROOT / 'tests/go-parity'}:{ROOT / 'dashboard'}",
        PYTEST_PLUGINS="",
        PYTEST_ADDOPTS="",
        PYTHONPYCACHEPREFIX=str(ROOT / ".go-cache/pycache"),
        COVERAGE_FILE=str(tmp_path / "reference.coverage"),
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
            "dashboard_worker_detail_plugin",
            "tests/client/test_rig_config_meta.py::test_a_control_change_we_have_a_record_of_and_that_held_is_ours",
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
