import json
import os
import subprocess
import sys
from pathlib import Path

import pytest

# ruff: noqa: S101, S603, S607

ROOT = Path(__file__).resolve().parents[2]


@pytest.mark.parametrize(
    ("relative", "seam", "replacement", "test"),
    [
        (
            "control/operations.go",
            "func submit(command Request) (any, error) {",
            'func submit(command Request) (any, error) {\nreturn nil, valueError("source mutation")',
            "tests/service/test_control_service.py::TestSubmit::test_submit_writes_request_json",
        ),
        (
            "wizard/wizard.go",
            "func (v View) Stage() (string, error) {",
            'func (v View) Stage() (string, error) {\nreturn "source mutation", nil',
            "tests/web/test_wizard_setup_and_install.py",
        ),
    ],
)
def test_source_mutation_breaks_the_unchanged_oracle(tmp_path, relative, seam, replacement, test):
    original = ROOT / "go/internal/dashboard" / relative
    source = original.read_text()
    assert source.count(seam) == 1
    altered = tmp_path / "mutated.go"
    altered.write_text(source.replace(seam, replacement))
    overlay = tmp_path / "overlay.json"
    overlay.write_text(json.dumps({"Replace": {str(original): str(altered)}}))
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
    env.update(
        PITHEAD_IMPL="go",
        PITHEAD_DASHBOARD_GO_BINARY=str(binary),
        PYTHONPATH=f"{ROOT / 'tests/go-parity'}:{ROOT / 'dashboard'}",
        PYTEST_PLUGINS="",
        PYTEST_ADDOPTS="",
        COVERAGE_FILE=str(tmp_path / "mutation.coverage"),
    )
    result = subprocess.run(
        [sys.executable, "-m", "pytest", "-p", "dashboard_channel_plugin", test],
        cwd=ROOT / "dashboard",
        env=env,
        capture_output=True,
        text=True,
        timeout=90,
        check=False,
    )
    assert result.returncode == 1
    assert "source mutation" in result.stdout
