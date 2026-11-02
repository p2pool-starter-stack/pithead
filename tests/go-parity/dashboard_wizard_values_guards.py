import json
import os
import subprocess
import sys
from pathlib import Path

import pytest

# ruff: noqa: S101, S603, S607

ROOT = Path(__file__).resolve().parents[2]
SOURCE = ROOT / "go/internal/dashboard/wizard/values.go"


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
    ("seam", "replacement", "test", "failure", "native_evidence"),
    [
        (
            'if strictConfigEqual(held, &ConfigValue{Kind: "bool", Bool: true}) {',
            'if false && strictConfigEqual(held, &ConfigValue{Kind: "bool", Bool: true}) {',
            "tests/web/test_wizard_defaults.py::"
            "test_booted_data_disk_that_holds_a_tari_chain_keeps_local",
            "assert 'off' == 'local'",
            '"tari": 1',
        ),
        (
            'if ok && block.Kind == "dict" {',
            'if false && ok && block.Kind == "dict" {',
            "tests/web/test_config_defaults.py::"
            "test_sparse_browser_submit_materializes_defaults_without_replacing_answers[False-diy]",
            "KeyError",
            '"explicit": 1',
        ),
    ],
)
def test_source_mutation_breaks_unchanged_wizard_values_oracle(
    tmp_path, seam, replacement, test, failure, native_evidence
):
    binary = _mutated_binary(tmp_path, seam, replacement)
    env = os.environ.copy()
    env.update(
        PITHEAD_IMPL="go",
        PITHEAD_DASHBOARD_GO_BINARY=str(binary),
        PYTHONPATH=f"{ROOT / 'tests/go-parity'}:{ROOT / 'dashboard'}",
        PYTEST_PLUGINS="",
        PYTEST_ADDOPTS="",
        PYTHONPYCACHEPREFIX=str(ROOT / ".go-cache/pycache"),
        COVERAGE_FILE=str(tmp_path / "mutation.coverage"),
        WIZARD_RESTORE=str(tmp_path / "restore"),
        WIZARD_HANDOFF=str(tmp_path / "handoff"),
    )
    result = subprocess.run(
        [
            sys.executable,
            "-m",
            "pytest",
            "-p",
            "no:cacheprovider",
            "-p",
            "dashboard_wizard_values_plugin",
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
