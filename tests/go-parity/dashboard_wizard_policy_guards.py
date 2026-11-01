import json
import os
import subprocess
import sys
from pathlib import Path

import pytest

# ruff: noqa: S101, S603, S607

ROOT = Path(__file__).resolve().parents[2]


@pytest.mark.parametrize(
    ("source_name", "seam", "replacement", "test", "failure", "native_evidence"),
    [
        (
            "auth.go",
            "func loginToken(request authRequest) (authLogin, error) {",
            "func loginToken(request authRequest) (authLogin, error) {\n"
            "return authLogin{Accepted: true, Failures: request.Failures, Status: 302}, nil",
            "tests/web/test_wizard_setup_and_install.py::test_wrong_token_403",
            "assert 302 == 403",
            '"wizard-auth:login": 1',
        ),
        (
            "form.go",
            "func BuildConfigPlan(request FormRequest) ([]FormOperation, error) {",
            "func BuildConfigPlan(request FormRequest) ([]FormOperation, error) {\n"
            "return []FormOperation{}, nil",
            "tests/web/test_wizard_form.py::test_a_remote_node_that_needs_a_login_carries_one",
            "KeyError",
            '"wizard-form:build": 1',
        ),
    ],
)
def test_source_mutation_breaks_unchanged_wizard_policy_oracle(
    tmp_path, source_name, seam, replacement, test, failure, native_evidence
):
    original = ROOT / "go/internal/dashboard/wizard" / source_name
    source = original.read_text()
    assert source.count(seam) == 1
    altered = tmp_path / source_name
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
        [sys.executable, "-m", "pytest", "-p", "dashboard_wizard_policy_plugin", test],
        cwd=ROOT / "dashboard",
        env=env,
        capture_output=True,
        text=True,
        timeout=90,
        check=False,
    )
    assert result.returncode == 1
    assert "1 failed" in result.stdout
    assert failure in result.stdout
    assert native_evidence in result.stdout
