import json
import os
import subprocess
import sys
from pathlib import Path

import pytest

# ruff: noqa: S101, S603, S607

ROOT = Path(__file__).resolve().parents[2]
SOURCE = ROOT / "go/internal/dashboard/wizard/documents.go"


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
    ("seam", "replacement", "test", "failure", "operation", "calls"),
    [
        (
            "if _, ok := seen[key]; ok {",
            "if _, ok := seen[key]; false && ok {",
            "tests/config/test_documents.py::test_duplicate_keys_refused",
            "6 failed",
            "decode:error",
            6,
        ),
        (
            'if strings.HasPrefix(upper, "PASTE_") || strings.HasPrefix(upper, "YOUR_") {',
            'if false && (strings.HasPrefix(upper, "PASTE_") || '
            'strings.HasPrefix(upper, "YOUR_")) {',
            "tests/config/test_documents.py::test_untrusted_key_diagnostics_escape_controls",
            "DID NOT RAISE",
            "placeholders",
            1,
        ),
    ],
)
def test_source_mutation_breaks_unchanged_documents_oracle(
    tmp_path, seam, replacement, test, failure, operation, calls
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
        PITHEAD_DOCUMENTS_TRACE=str(trace),
    )
    result = subprocess.run(
        [
            sys.executable,
            "-m",
            "pytest",
            "-p",
            "no:cacheprovider",
            "-p",
            "dashboard_documents_plugin",
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
    assert failure in result.stdout
    assert trace.read_text().splitlines().count(operation) == calls
