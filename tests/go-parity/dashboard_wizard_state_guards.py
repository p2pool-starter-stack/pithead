import json
import os
import subprocess
import sys
from pathlib import Path

import pytest

# ruff: noqa: S101, S603, S607

ROOT = Path(__file__).resolve().parents[2]
SOURCE = ROOT / "go/internal/dashboard/wizard/state.go"


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
    ("seam", "replacement", "test", "message"),
    [
        (
            "Config: DeepMerge(reference, selected),",
            "Config: reference,",
            "tests/web/test_wizard_setup_and_install.py::"
            "test_a_rejected_attempt_comes_back_in_the_state",
            "assert '' == '4TYPO'",
        ),
        (
            '{Key: "node_probe", Value: stateValue(request.NodeProbe)},',
            '{Key: "node_probe", Value: stateValue(nil)},',
            "tests/web/test_wizard_probe.py::"
            "test_a_failing_report_keeps_every_row_so_the_page_can_say_which_leg_failed",
            "TypeError",
        ),
    ],
)
def test_source_mutation_breaks_unchanged_wizard_state_oracle(
    tmp_path, seam, replacement, test, message
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
        PITHEAD_WIZARD_STATE_TRACE=str(trace),
    )
    result = subprocess.run(
        [
            sys.executable,
            "-m",
            "pytest",
            "-p",
            "no:cacheprovider",
            "-p",
            "dashboard_wizard_state_plugin",
            test,
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
    assert message in result.stdout
    assert trace.read_text().splitlines() == ["prepare", "config", "response"]
