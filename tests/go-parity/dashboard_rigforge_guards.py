import json
import os
import subprocess
import sys
from pathlib import Path

import pytest

# ruff: noqa: S101, S603, S607

ROOT = Path(__file__).resolve().parents[2]
RIGFORGE_SOURCE = ROOT / "go/internal/dashboard/fleet/poll_rigforge.go"
CREDENTIAL_SOURCE = ROOT / "go/internal/dashboard/fleet/detail_drift.go"


def _mutated_binary(tmp_path, source, seam, replacement):
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


def _run_oracle(tmp_path, binary, test):
    trace = tmp_path / "native.trace"
    env = os.environ.copy()
    env.update(
        PITHEAD_IMPL="go",
        TZ="UTC",
        PITHEAD_DASHBOARD_GO_BINARY=str(binary),
        PITHEAD_RIGFORGE_TRACE=str(trace),
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
            "dashboard_rigforge_plugin",
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


def test_source_mutation_breaks_unchanged_version_oracle(tmp_path):
    binary = _mutated_binary(
        tmp_path,
        RIGFORGE_SOURCE,
        '"version":      member(rf, "version", nil),',
        '"version":      member(rf, "missing", nil),',
    )
    result, trace = _run_oracle(
        tmp_path,
        binary,
        "dashboard/tests/client/test_xmrig_client.py::test_parse_rigforge_full_block",
    )
    assert result.returncode == 1
    assert "1 failed" in result.stdout
    assert trace.read_text().splitlines() == ["poll_parse_rigforge"]


def test_source_mutation_breaks_credential_redaction_oracle(tmp_path):
    binary = _mutated_binary(
        tmp_path,
        CREDENTIAL_SOURCE,
        'if key == "pass" || key == "tls-fingerprint" {',
        'if key == "tls-fingerprint" {',
    )
    result, trace = _run_oracle(
        tmp_path,
        binary,
        "dashboard/tests/client/test_rigforge_config.py::TestRigWritableConfig::"
        "test_pool_credentials_are_masked_even_if_the_rig_sends_them",
    )
    assert result.returncode == 1
    assert "1 failed" in result.stdout
    assert trace.read_text().splitlines() == ["poll_parse_rigforge"]


@pytest.mark.parametrize("implementation", [None, "bash", "python"])
def test_reference_selection_never_invokes_native_rigforge_parser(tmp_path, implementation):
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
            "dashboard_rigforge_plugin",
            "tests/client/test_rigforge_freshness.py",
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
