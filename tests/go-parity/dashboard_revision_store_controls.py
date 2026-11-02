import json
import os
import re
import subprocess
import sys
from pathlib import Path

import pytest

# ruff: noqa: S101, S603, S607

ROOT = Path(__file__).resolve().parents[2]
ORACLE = "tests/web/test_worker_config_drift.py"
SOURCE = ROOT / "go/internal/dashboard/storage/revision.go"


def _environment(tmp_path):
    env = os.environ.copy()
    env.update(
        PITHEAD_IMPL="go",
        TZ="UTC",
        PYTHONPATH=f"{ROOT / 'tests/go-parity'}:{ROOT / 'dashboard'}",
        PYTEST_ADDOPTS="",
        PYTEST_PLUGINS="",
        COVERAGE_FILE=str(tmp_path / "revision-store-controls.coverage"),
    )
    return env


def _pytest(env, *arguments):
    return subprocess.run(
        [
            sys.executable,
            "-m",
            "pytest",
            "-p",
            "dashboard_revision_store_plugin",
            *arguments,
            "--no-cov",
        ],
        cwd=ROOT / "dashboard",
        env=env,
        text=True,
        capture_output=True,
        timeout=120,
        check=False,
    )


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
        text=True,
        capture_output=True,
        timeout=120,
        check=False,
    )
    assert result.returncode == 0, result.stderr
    return binary


@pytest.mark.parametrize(
    ("seam", "replacement"),
    [
        (
            '"INSERT OR REPLACE INTO worker_config_revision (worker, revision, last_change_id, ts, drift_from) VALUES (?, ?, ?, ?, ?)",',
            '"INSERT OR REPLACE INTO missing_revision_table (worker) VALUES (?)",',
        ),
        (
            '"SELECT revision, drift_from FROM worker_config_revision WHERE worker = ?",',
            '"SELECT revision, drift_from FROM missing_revision_table WHERE worker = ?",',
        ),
    ],
)
def test_source_mutation_breaks_unchanged_oracle(tmp_path, seam, replacement):
    env = _environment(tmp_path)
    env["PITHEAD_DASHBOARD_GO_BINARY"] = str(_mutated_binary(tmp_path, seam, replacement))
    result = _pytest(env, ORACLE)
    assert result.returncode == 1
    assert "failed" in result.stdout


def test_unchanged_oracle_reaches_native_revision_operations_under_xdist(tmp_path):
    env = _environment(tmp_path)
    env["PITHEAD_DASHBOARD_GO_BINARY"] = str(ROOT / "go/bin/dashboard")
    result = _pytest(env, ORACLE, "-n", "1")
    output = result.stdout + result.stderr
    assert result.returncode == 0, output
    for operation in ("prepare", "write", "drift"):
        assert re.search(rf"worker-revision-{operation}\": [1-9][0-9]*", output)
    assert "native revision storage errors {}" in output
    assert "unexpected revision storage fallbacks {}" in output
    assert "intentional revision storage compatibility {}" in output


def test_reference_guard_records_its_failure(tmp_path):
    oracle = tmp_path / "test_reference_guard.py"
    oracle.write_text(
        "def test_reference_call():\n"
        "    from mining_dashboard import go_revision_store\n"
        "    go_revision_store.REFERENCE_FUNCTIONS['visible'](None, 'revision')\n"
    )
    result = _pytest(_environment(tmp_path), str(oracle))
    output = result.stdout + result.stderr
    assert result.returncode == 1, output
    assert "reference revision storage used in Go mode" in output
    assert 'unexpected revision storage fallbacks {"unexpected": 1}' in output


@pytest.mark.parametrize("selector", [None, "bash", "python"])
def test_reference_selectors_do_not_invoke_native(tmp_path, selector):
    marker = tmp_path / "called"
    binary = tmp_path / "dashboard"
    binary.write_text('#!/bin/sh\n: > "$PITHEAD_SENTINEL_MARKER"\nexit 99\n')
    binary.chmod(0o755)
    env = _environment(tmp_path)
    env.update(
        PITHEAD_DASHBOARD_GO_BINARY=str(binary),
        PITHEAD_SENTINEL_MARKER=str(marker),
    )
    if selector is None:
        env.pop("PITHEAD_IMPL", None)
    else:
        env["PITHEAD_IMPL"] = selector
    result = _pytest(env, ORACLE, "-q")
    assert result.returncode == 0, result.stdout + result.stderr
    assert not marker.exists()
