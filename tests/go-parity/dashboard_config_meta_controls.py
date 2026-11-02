import json
import os
import re
import subprocess
import sys
from pathlib import Path

import pytest

# ruff: noqa: S101, S603, S607

ROOT = Path(__file__).resolve().parents[2]
SOURCE = ROOT / "go/internal/dashboard/fleet/config_meta_policy.go"
ORACLE = "tests/client/test_rig_config_meta.py::test_a_well_formed_block_survives_whole"
FLOW_ORACLE = "tests/client/test_rig_config_meta.py::test_parse_rigforge_carries_the_block_through"


def _environment(tmp_path):
    env = os.environ.copy()
    env.update(
        PITHEAD_IMPL="go",
        TZ="UTC",
        PYTHONPATH=f"{ROOT / 'tests/go-parity'}:{ROOT / 'dashboard'}",
        PYTEST_PLUGINS="",
        PYTEST_ADDOPTS="",
        PYTHONPYCACHEPREFIX=str(ROOT / ".go-cache/pycache"),
        COVERAGE_FILE=str(tmp_path / "config-meta-controls.coverage"),
    )
    return env


def _pytest(arguments, env):
    return subprocess.run(
        [
            sys.executable,
            "-m",
            "pytest",
            "-p",
            "no:cacheprovider",
            "-p",
            "dashboard_config_meta_plugin",
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


def _mutated_binary(tmp_path):
    text = SOURCE.read_text()
    seam = 'Revision:     meta["revision"] != nil,'
    assert text.count(seam) == 1
    altered = tmp_path / SOURCE.name
    altered.write_text(text.replace(seam, 'Revision:     meta["revision"] == nil,'))
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


def test_source_mutation_breaks_unchanged_oracle(tmp_path):
    env = _environment(tmp_path)
    env["PITHEAD_DASHBOARD_GO_BINARY"] = str(_mutated_binary(tmp_path))
    result = _pytest([ORACLE], env)
    assert result.returncode == 1
    assert "1 failed" in result.stdout


def test_unchanged_oracles_reach_native_policy_under_xdist(tmp_path):
    env = _environment(tmp_path)
    env["PITHEAD_DASHBOARD_GO_BINARY"] = str(ROOT / "go/bin/dashboard")
    result = _pytest([ORACLE, FLOW_ORACLE, "-n", "1"], env)
    output = result.stdout + result.stderr
    assert result.returncode == 0, output
    assert re.search(r'native config metadata calls \{"config_meta_policy": [1-9][0-9]*\}', output)
    assert "native config metadata errors {}" in output
    assert "unexpected config metadata fallbacks {}" in output
    assert "intentional config metadata compatibility {}" in output


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
    result = _pytest([ORACLE], env)
    assert result.returncode == 0, result.stdout + result.stderr
    assert not marker.exists()
