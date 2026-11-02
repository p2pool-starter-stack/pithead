import json
import os
import subprocess
import sys
from pathlib import Path

import pytest

# ruff: noqa: S101, S603, S607

ROOT = Path(__file__).resolve().parents[2]
SOURCE = ROOT / "go/internal/dashboard/controlhttp/worker.go"


def _mutated_binary(tmp_path, seam, replacement):
    source = SOURCE.read_text()
    assert source.count(seam) == 1
    altered = tmp_path / SOURCE.name
    altered.write_text(source.replace(seam, replacement))
    overlay = tmp_path / "overlay.json"
    overlay.write_text(json.dumps({"Replace": {str(SOURCE): str(altered)}}))
    binary = tmp_path / "dashboard"
    env = os.environ.copy()
    env.update(
        GOCACHE=str(ROOT / ".go-cache/build"),
        GOMODCACHE=str(ROOT / ".go-cache/mod"),
        GOPATH=str(ROOT / ".go-cache/gopath"),
        TMPDIR=str(ROOT / ".go-cache/tmp"),
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


@pytest.mark.parametrize(
    ("seam", "replacement", "test", "operation"),
    [
        (
            "if _, ok := recordableWorkerStatuses[status.Text]; !ok {",
            "if true {",
            "tests/web/test_server_worker_inspect.py::TestWorkerInspect::"
            "test_worker_apply_spools_tokenless_intent_and_records_history",
            "worker-record:",
        ),
        (
            'if field.Key == "pass" || field.Key == "tls-fingerprint" {',
            'if false && (field.Key == "pass" || field.Key == "tls-fingerprint") {',
            "tests/web/test_server_worker_inspect.py::TestWorkerInspect::"
            "test_worker_apply_spools_tokenless_intent_and_records_history",
            "worker-strip:",
        ),
    ],
)
def test_source_mutation_breaks_unchanged_worker_http_oracle(
    tmp_path, seam, replacement, test, operation
):
    binary = _mutated_binary(tmp_path, seam, replacement)
    trace = tmp_path / "native.trace"
    env = os.environ.copy()
    env.update(
        PITHEAD_IMPL="go",
        PITHEAD_DASHBOARD_GO_BINARY=str(binary),
        PYTHONPATH=f"{ROOT / 'tests/go-parity'}:{ROOT / 'dashboard'}",
        PYTEST_PLUGINS="",
        PYTEST_ADDOPTS="",
        PYTHONPYCACHEPREFIX=str(ROOT / ".go-cache/pycache"),
        COVERAGE_FILE=str(tmp_path / "mutation.coverage"),
        PITHEAD_WORKER_HTTP_TRACE=str(trace),
    )
    result = subprocess.run(
        [
            sys.executable,
            "-m",
            "pytest",
            "-p",
            "no:cacheprovider",
            "-p",
            "dashboard_worker_http_plugin",
            test,
        ],
        cwd=ROOT / "dashboard",
        env=env,
        capture_output=True,
        text=True,
        timeout=90,
        check=False,
    )
    assert result.returncode == 1
    assert "1 failed" in result.stdout
    assert any(line.startswith(operation) for line in trace.read_text().splitlines())


@pytest.mark.parametrize("implementation", [None, "bash", "python"])
def test_reference_selection_never_invokes_native_worker_helper(tmp_path, implementation):
    marker = tmp_path / "called"
    binary = tmp_path / "dashboard"
    binary.write_text('#!/bin/sh\n: > "$PITHEAD_SENTINEL_MARKER"\nexit 99\n')
    binary.chmod(0o755)
    env = os.environ.copy()
    env.update(
        PITHEAD_DASHBOARD_GO_BINARY=str(binary),
        PYTHONPATH=f"{ROOT / 'tests/go-parity'}:{ROOT / 'dashboard'}",
        PYTEST_PLUGINS="",
        PYTEST_ADDOPTS="",
        PYTHONPYCACHEPREFIX=str(ROOT / ".go-cache/pycache"),
        COVERAGE_FILE=str(tmp_path / "reference.coverage"),
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
            "dashboard_worker_http_plugin",
            "tests/web/test_server_worker_inspect.py::TestWorkerInspect::"
            "test_worker_detail_requires_name",
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
