import json
import os
import subprocess
import sys
from pathlib import Path

import pytest

# ruff: noqa: S101, S603, S607

ROOT = Path(__file__).resolve().parents[2]
SOURCE = ROOT / "go/internal/dashboard/wizard/submission.go"


def _mutated_binary(tmp_path, replacement):
    source = SOURCE.read_text()
    assert source.count(replacement[0]) == 1
    altered = tmp_path / SOURCE.name
    altered.write_text(source.replace(*replacement))
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
    ("seam", "replacement", "test", "failure"),
    [
        (
            '"rig-request.json"',
            '"broken-rig-request.json"',
            "tests/web/test_wizard_handoff_rig_and_restore.py::"
            "test_rig_submit_writes_the_request_and_role_and_no_config",
            "FileNotFoundError",
        ),
        (
            "Volatile: !request.Encrypted",
            "Volatile: request.Encrypted",
            "tests/web/test_wizard_handoff_rig_and_restore.py::"
            "test_restore_writes_the_archive_and_passphrase_and_clears_a_previous_error",
            "FileNotFoundError",
        ),
    ],
)
def test_source_mutation_breaks_unchanged_submission_oracle(
    tmp_path, seam, replacement, test, failure
):
    binary = _mutated_binary(tmp_path, (seam, replacement))
    env = os.environ.copy()
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
            "dashboard_wizard_submission_plugin",
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
    assert "native wizard submission calls" in result.stdout
