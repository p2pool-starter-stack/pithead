import json
import os
import subprocess
from pathlib import Path

import pytest

# ruff: noqa: S101, S603, S607

ROOT = Path(__file__).resolve().parents[2]
HARNESS = ROOT / "tests/go-parity/keep_running_reference.sh"


def _run(binary, implementation="go"):
    env = os.environ.copy()
    env.update(
        PITHEAD_IMPL=implementation,
        PITHEAD_GO_BINARY=str(binary),
        PITHEAD_GO_CONFIG_DOCUMENT_BINARY=str(binary),
        PITHEAD_UNTRUSTED_MACOS_RUN="1",
        PITHEAD_SCOPE_ONLY_KEEP="1",
    )
    return subprocess.run(
        ["bash", str(HARNESS)],
        cwd=ROOT,
        env=env,
        text=True,
        capture_output=True,
        timeout=60,
        check=False,
    )


def _wrapper(tmp_path, binary):
    calls = tmp_path / "calls"
    statuses = tmp_path / "statuses"
    wrapper = tmp_path / "pithead"
    wrapper.write_text(
        "#!/bin/sh\n"
        f'if [ "$PITHEAD_GO_HELPER" != keep-running-scope ]; then exec "{binary}" "$@"; fi\n'
        f'printf "%s\\n" "$PITHEAD_GO_HELPER" >> "{calls}"\n'
        f'"{binary}" "$@"\n'
        "rc=$?\n"
        f'printf "%s %d\\n" "$PITHEAD_GO_HELPER" "$rc" >> "{statuses}"\n'
        'exit "$rc"\n'
    )
    wrapper.chmod(0o755)
    return wrapper, calls, statuses


def _assert_native_success(statuses):
    assert statuses.read_text().splitlines() == ["keep-running-scope 0"] * 4


def _mutated_binary(tmp_path, source, seam, replacement):
    text = source.read_text()
    assert text.count(seam) == 1
    altered = tmp_path / source.name
    altered.write_text(text.replace(seam, replacement))
    overlay = tmp_path / "overlay.json"
    overlay.write_text(json.dumps({"Replace": {str(source): str(altered)}}))
    binary = tmp_path / f"pithead-{source.stem}"
    env = os.environ.copy()
    env.update(
        GOCACHE=str(ROOT / ".go-cache/build"),
        GOMODCACHE=str(ROOT / ".go-cache/mod"),
        GOPATH=str(ROOT / ".go-cache/gopath"),
        GOTMPDIR=str(ROOT / ".go-cache/tmp"),
        GOPROXY="off",
    )
    result = subprocess.run(
        ["go", "build", "-overlay", str(overlay), "-o", str(binary), "./cmd/pithead"],
        cwd=ROOT / "go",
        env=env,
        text=True,
        capture_output=True,
        timeout=120,
        check=False,
    )
    assert result.returncode == 0, result.stderr
    return binary


def test_unchanged_scope_oracle_reaches_native_helper(tmp_path):
    wrapper, calls, statuses = _wrapper(tmp_path, ROOT / "go/bin/pithead")
    result = _run(wrapper)
    assert result.returncode == 0, result.stdout + result.stderr
    selected = [call for call in calls.read_text().splitlines() if call == "keep-running-scope"]
    assert selected == ["keep-running-scope"] * 4
    _assert_native_success(statuses)


def test_native_helper_125_uses_reference_compatibility(tmp_path):
    helper = tmp_path / "helper"
    helper.write_text("#!/bin/sh\nexit 125\n")
    helper.chmod(0o755)
    result = _run(helper)
    assert result.returncode == 0, result.stdout + result.stderr


def test_forced_unsupported_mutation_is_visible_to_strict_guard(tmp_path):
    source = ROOT / "go/internal/cli/keep_running_scope.go"
    binary = _mutated_binary(tmp_path, source, "if len(args) != 0 {", "if len(args) == 0 {")
    wrapper, calls, statuses = _wrapper(tmp_path, binary)
    result = _run(wrapper)
    assert result.returncode == 0, result.stdout + result.stderr
    assert calls.read_text().splitlines() == ["keep-running-scope"] * 4
    assert statuses.read_text().splitlines() == ["keep-running-scope 125"] * 4
    with pytest.raises(AssertionError):
        _assert_native_success(statuses)


def test_wrong_native_plan_breaks_unchanged_oracle(tmp_path):
    source = ROOT / "go/internal/lifecycle/keep_running.go"
    binary = _mutated_binary(
        tmp_path,
        source,
        "if len(services) == 0 {",
        "if len(services) >= 0 {",
    )
    result = _run(binary)
    assert result.returncode == 1
    assert "✗" in result.stdout


@pytest.mark.parametrize(
    "body",
    [
        "printf '99999\\0'",
        "printf '1\\0'",
        "printf '0\\0trailing\\0'",
    ],
)
def test_malformed_native_reply_uses_reference_compatibility(tmp_path, body):
    helper = tmp_path / "helper"
    helper.write_text(f"#!/bin/sh\n{body}\n")
    helper.chmod(0o755)
    result = _run(helper)
    assert result.returncode == 0, result.stdout + result.stderr
    assert "integer expression expected" not in result.stderr


@pytest.mark.parametrize("implementation", ["", "bash", "python"])
def test_reference_selectors_never_invoke_native(tmp_path, implementation):
    marker = tmp_path / "called"
    helper = tmp_path / "helper"
    helper.write_text(f"#!/bin/sh\n: > '{marker}'\nexit 99\n")
    helper.chmod(0o755)
    result = _run(helper, implementation)
    assert result.returncode == 0, result.stdout + result.stderr
    assert not marker.exists()
