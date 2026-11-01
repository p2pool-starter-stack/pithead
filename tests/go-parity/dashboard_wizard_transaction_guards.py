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
            "func (t Txn) WriteStream(name string, input io.Reader, length int64, directory string) error {",
            "func (t Txn) WriteStream(name string, input io.Reader, length int64, directory string) error {\n"
            'return fmt.Errorf("source mutation unsupported")',
            "tests/web/test_wizard_restore_security.py::"
            "test_plaintext_restore_upload_stays_volatile",
            "assert 500 == 200",
            '"write:OSError": 1',
        ),
        (
            "func (t Txn) ClearTemps() bool {",
            "func (t Txn) ClearTemps() bool {\nreturn true",
            "tests/web/test_wizard_restore_security.py::"
            "test_server_restart_reports_unsafe_temp_cleanup_without_content",
            "DID NOT RAISE",
            '"clear-temps": 1',
        ),
    ],
)
def test_source_mutation_breaks_the_unchanged_wizard_oracle(
    tmp_path, seam, replacement, test, failure, native_evidence
):
    original = ROOT / "go/internal/dashboard/wizard/transactions.go"
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
        [
            sys.executable,
            "-m",
            "pytest",
            "-p",
            "dashboard_wizard_transaction_plugin",
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
