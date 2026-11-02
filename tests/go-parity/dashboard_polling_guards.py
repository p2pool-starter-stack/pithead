import json
import os
import subprocess
import sys
from pathlib import Path

import pytest

# ruff: noqa: S101, S603, S607

ROOT = Path(__file__).resolve().parents[2]
STATE_SOURCE = ROOT / "go/internal/dashboard/fleet/poll_state.go"


def _mutated_binary(tmp_path, seam, replacement):
    text = STATE_SOURCE.read_text()
    assert text.count(seam) == 1
    altered = tmp_path / STATE_SOURCE.name
    altered.write_text(text.replace(seam, replacement))
    overlay = tmp_path / "overlay.json"
    overlay.write_text(json.dumps({"Replace": {str(STATE_SOURCE): str(altered)}}))
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
        PITHEAD_POLLING_TRACE=str(trace),
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
            "dashboard_polling_plugin",
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


def test_source_mutation_breaks_stale_lifecycle_oracle(tmp_path):
    binary = _mutated_binary(
        tmp_path,
        "if state.seen {",
        "if state.seen && len(liveIndices) > 0 {",
    )
    result, trace = _run_oracle(
        tmp_path,
        binary,
        "dashboard/tests/service/test_data_helpers.py::TestWorkerLifecycle::"
        "test_fallen_off_worker_stays_gone_while_proxy_keeps_reporting_it",
    )
    assert result.returncode == 1
    assert "1 failed" in result.stdout
    assert "poll_lifecycle" in trace.read_text().splitlines()


def test_source_mutation_breaks_probe_selection_oracle(tmp_path):
    binary = _mutated_binary(
        tmp_path,
        'wanted := member(worker, "status", nil) == "online"',
        'wanted := true || member(worker, "status", nil) == "online"',
    )
    result, trace = _run_oracle(
        tmp_path,
        binary,
        "dashboard/tests/service/test_worker_probe.py::"
        "test_offline_row_whose_last_probe_failed_is_not_probed_or_badged",
    )
    assert result.returncode == 1
    assert "1 failed" in result.stdout
    assert "poll_probe_plan" in trace.read_text().splitlines()


@pytest.mark.parametrize("implementation", [None, "bash", "python"])
def test_reference_selection_never_invokes_native_polling_helper(tmp_path, implementation):
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
            "dashboard_polling_plugin",
            "tests/service/test_data_helpers.py::TestSharesToRecord::test_delta_records_the_difference",
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


def test_native_wrappers_reject_invalid_state_shapes(monkeypatch):
    from mining_dashboard import go_polling
    from mining_dashboard.service import data_helpers

    monkeypatch.setattr(go_polling, "_run", lambda *args, **kwargs: [])
    with pytest.raises(RuntimeError, match="invalid data"):
        data_helpers.WorkerLifecycle(10).update([], 1.0)


@pytest.mark.asyncio
async def test_native_probe_rejects_invalid_plan_shape(monkeypatch):
    from mining_dashboard import go_polling
    from mining_dashboard.service.worker_probe import WorkerProber

    monkeypatch.setattr(go_polling, "_run", lambda *args, **kwargs: [1])
    with pytest.raises(RuntimeError, match="invalid plan"):
        await WorkerProber().probe(None, [])
