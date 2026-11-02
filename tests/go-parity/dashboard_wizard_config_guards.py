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
            "config_prepare.go",
            "func PrepareConfig(cfg, ref, legacyDefaults *ConfigValue, reject bool) "
            "(*ConfigValue, []string, error) {",
            "func PrepareConfig(cfg, ref, legacyDefaults *ConfigValue, reject bool) "
            "(*ConfigValue, []string, error) {\n\treturn configDict(), []string{}, nil",
            "tests/web/test_wizard_recovery.py::"
            "test_prepare_config_moves_both_removed_1x_shapes_before_schema_filtering",
            "KeyError",
            '"prepare": 1',
        ),
        (
            "config_ops.go",
            "func RecoveryState(changes, attempt, disks, mode *ConfigValue) "
            "([]string, *ConfigValue, string, error) {",
            "func RecoveryState(changes, attempt, disks, mode *ConfigValue) "
            "([]string, *ConfigValue, string, error) {\n"
            '\treturn []string{}, configDict(), "auto", nil',
            "tests/web/test_wizard_recovery.py::"
            "test_failed_install_refresh_and_return_keep_safe_editable_fields",
            "assert {} ==",
            '"recovery":',
        ),
    ],
)
def test_source_mutation_breaks_unchanged_wizard_config_oracle(
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
        [sys.executable, "-m", "pytest", "-p", "dashboard_wizard_config_plugin", test],
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
