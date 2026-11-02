import json
import os
import subprocess
import sys
from pathlib import Path

import pytest

# ruff: noqa: S101, S603, S607

ROOT = Path(__file__).resolve().parents[2]


@pytest.mark.parametrize(
    ("seam", "replacement", "test", "failure", "native_evidence"),
    [
        (
            'if raw == nil || *raw == "" {',
            "if false {",
            "tests/web/test_wizard_handoff_rig_and_restore.py::"
            "test_handoff_404s_until_the_host_publishes_it",
            "assert 500 == 404",
            '"wizard-terminal:handoff": 1',
        ),
        (
            'if err := (Txn{Spool: spool, IO: io}).Write("handoff-ack", []byte("1"), ""); '
            "err != nil {\n\t\t\treturn TerminalResult{}, err\n\t\t}",
            "if false {\n\t\t\treturn TerminalResult{}, nil\n\t\t}",
            "tests/web/test_wizard_handoff_rig_and_restore.py::"
            "test_ack_needs_auth_and_a_published_handoff",
            "FileNotFoundError",
            '"wizard-terminal:ack": 2',
        ),
        (
            'if !ok || stage != "failed" {',
            'if ok && stage == "failed" {',
            "tests/web/test_wizard_recovery.py::"
            "test_retry_is_authenticated_and_only_opens_a_real_failure",
            "assert 200 == 409",
            '"wizard-terminal:retry": 2',
        ),
    ],
)
def test_source_mutation_breaks_unchanged_wizard_terminal_oracle(
    tmp_path, seam, replacement, test, failure, native_evidence
):
    original = ROOT / "go/internal/dashboard/wizard/terminal.go"
    source = original.read_text()
    assert source.count(seam) == 1
    altered = tmp_path / "terminal.go"
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
        UV_CACHE_DIR=str(ROOT / ".uv-cache"),
        PYTHONPYCACHEPREFIX=str(ROOT / ".go-cache/pycache"),
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
        [
            sys.executable,
            "-m",
            "pytest",
            "-p",
            "no:cacheprovider",
            "-p",
            "dashboard_wizard_terminal_plugin",
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
    assert failure in result.stdout
    assert native_evidence in result.stdout
