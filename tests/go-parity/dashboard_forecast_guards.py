import json
import os
import subprocess
import sys
from pathlib import Path

# ruff: noqa: S101, S603, S607

ROOT = Path(__file__).resolve().parents[2]
FORECAST_SOURCE = ROOT / "go/internal/dashboard/overview/forecast_model.go"
RUNTIME_SOURCE = ROOT / "go/internal/dashboard/runtime/domain.go"


def build_overlay(tmp_path, source, seam, replacement):
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
    return binary, env


def run_oracle(tmp_path, binary, env, test):
    trace = tmp_path / "native.trace"
    env.update(
        PITHEAD_IMPL="go",
        PITHEAD_DASHBOARD_GO_BINARY=str(binary),
        PITHEAD_FORECAST_TRACE=str(trace),
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
            "dashboard_forecast_plugin",
            str(ROOT / "tests/go-parity/dashboard_forecast_compare.py") + "::" + test,
        ],
        cwd=ROOT / "dashboard",
        env=env,
        capture_output=True,
        text=True,
        timeout=120,
        check=False,
    )
    return result, trace


def test_source_mutation_breaks_native_forecast_math_oracle(tmp_path):
    seam = "fraction := (settings.priorLow + settings.priorHigh) / 2"
    binary, env = build_overlay(tmp_path, FORECAST_SOURCE, seam, "fraction := float64(1)")
    result, trace = run_oracle(
        tmp_path, binary, env, "test_tempered_measured_prior_and_empty_match"
    )
    assert result.returncode == 1
    assert "1 failed" in result.stdout
    assert trace.read_text().splitlines().count("xvb_tempered_day") == 2


def test_disabled_native_forecast_breaks_http_ownership(tmp_path):
    seam = (
        'sections["xvb_forecast"], err = forecastSection('
        'metrics, sections["build_earnings"], fields["snapshot"])'
    )
    replacement = 'sections["xvb_forecast"], err = nil, dashboardweb.ErrInputsUnavailable'
    binary, env = build_overlay(tmp_path, RUNTIME_SOURCE, seam, replacement)
    result, _trace = run_oracle(tmp_path, binary, env, "test_http_state_owns_forecast_bodies")
    assert result.returncode == 1
    assert "1 failed" in result.stdout
    assert "assert 500 == 200" in result.stdout
