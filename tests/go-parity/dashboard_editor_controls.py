import json
import os
import re
import subprocess
import sys
from pathlib import Path

import pytest

# ruff: noqa: S101, S603, S607

ROOT = Path(__file__).resolve().parents[2]
SOURCE = ROOT / "go/internal/dashboard/wizard/editor_metadata.go"
ORACLE = (
    "tests/service/test_config_operations.py::test_every_reference_leaf_is_intentionally_classified"
)


def _mutated_binary(tmp_path):
    text = SOURCE.read_text()
    seam = "if named[path] && !free[path] && !confirm[path]"
    assert text.count(seam) == 1
    altered = tmp_path / SOURCE.name
    altered.write_text(
        text.replace(seam, "if false && named[path] && !free[path] && !confirm[path]")
    )
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


def test_source_mutation_breaks_unchanged_editor_oracle(tmp_path):
    binary = _mutated_binary(tmp_path)
    trace = tmp_path / "native.trace"
    env = os.environ.copy()
    env.update(
        PITHEAD_IMPL="go",
        PITHEAD_DASHBOARD_GO_BINARY=str(binary),
        PITHEAD_EDITOR_TRACE=str(trace),
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
            "dashboard_editor_plugin",
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
    assert trace.read_text().splitlines() == ["editor-metadata"]


def test_worker_process_native_counters_reach_the_controller(tmp_path):
    env = os.environ.copy()
    env.update(
        PITHEAD_IMPL="go",
        PYTHONPATH=f"{ROOT / 'tests/go-parity'}:{ROOT / 'dashboard'}",
        PYTEST_PLUGINS="",
        PYTEST_ADDOPTS="",
        PYTHONPYCACHEPREFIX=str(ROOT / ".go-cache/pycache"),
        COVERAGE_FILE=str(tmp_path / "worker.coverage"),
    )
    result = subprocess.run(
        [
            sys.executable,
            "-m",
            "pytest",
            "-p",
            "no:cacheprovider",
            "-p",
            "dashboard_editor_plugin",
            "-n",
            "1",
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
    assert result.returncode == 0, result.stdout + result.stderr
    match = re.search(r"native editor metadata calls (\{[^\n]+\})", result.stdout)
    assert match and json.loads(match.group(1)) == {"editor-metadata": 1}
    assert "unexpected editor metadata fallbacks {}" in result.stdout


@pytest.mark.parametrize("implementation", [None, "bash", "python"])
def test_reference_selection_never_invokes_native_editor(tmp_path, implementation):
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
            "dashboard_editor_plugin",
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
