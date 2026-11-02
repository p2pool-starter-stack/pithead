import json
import os
import sys
from pathlib import Path

import pytest

# ruff: noqa: S101, S603

sys.path.insert(0, str(Path(__file__).resolve().parent))
from test_stack_native_adapter import (  # noqa: E402
    ADAPTER,
    REPORT,
    ROOT,
    WRAPPER,
    fixture,
    run,
    selected_env,
)


def mutated_keep_running_binary(tmp_path):
    source = ROOT / "go/internal/cli/cli.go"
    text = source.read_text()
    seam = 'case "keep-running-scope":\n\t\treturn keepRunningScope(args, os.Stdin, stdout)'
    replacement = 'case "keep-running-scope":\n\t\treturn &ExitError{Code: 125}'
    assert text.count(seam) == 1
    altered = tmp_path / "cli.go"
    altered.write_text(text.replace(seam, replacement))
    overlay = tmp_path / "overlay.json"
    overlay.write_text(json.dumps({"Replace": {str(source): str(altered)}}))
    binary = tmp_path / "pithead-mutated"
    env = os.environ.copy()
    env.update(
        GOCACHE=str(ROOT / ".go-cache/build"),
        GOMODCACHE=str(ROOT / ".go-cache/mod"),
        GOPATH=str(ROOT / ".go-cache/gopath"),
        GOTMPDIR=str(ROOT / ".go-cache/tmp"),
        GOPROXY="off",
    )
    result = run(
        ["go", "build", "-overlay", str(overlay), "-o", str(binary), "./cmd/pithead"],
        env,
        cwd=ROOT / "go",
    )
    assert result.returncode == 0, result.stdout + result.stderr
    return binary


@pytest.fixture(scope="module")
def native_go_binary(tmp_path_factory):
    directory = tmp_path_factory.mktemp("stack-native-go")
    binary = directory / "pithead"
    env = os.environ.copy()
    env.update(
        GOCACHE=str(ROOT / ".go-cache/build"),
        GOMODCACHE=str(ROOT / ".go-cache/mod"),
        GOPATH=str(ROOT / ".go-cache/gopath"),
        GOTMPDIR=str(ROOT / ".go-cache/tmp"),
        GOPROXY="off",
    )
    result = run(["go", "build", "-o", str(binary), "./cmd/pithead"], env, cwd=ROOT / "go")
    assert result.returncode == 0, result.stdout + result.stderr
    return binary


def test_dispatch_and_fallback_trace_write_failures_stop_execution(tmp_path):
    trace = tmp_path / "native.trace"
    trace.mkdir()
    marker = tmp_path / "executed"
    native = tmp_path / "native"
    native.write_text('#!/bin/sh\ntouch "$EXECUTION_MARKER"\n')
    native.chmod(0o755)
    env = os.environ.copy()
    env.update(
        STACK_NATIVE_BINARY=str(native),
        STACK_NATIVE_LOG=str(trace),
        EXECUTION_MARKER=str(marker),
    )
    dispatched = run([str(WRAPPER), "status"], env)
    assert dispatched.returncode == 2
    assert not marker.exists()
    reference = tmp_path / "reference.sh"
    reference.write_text('touch "$EXECUTION_MARKER"\n')
    env.update(
        BASH_ENV=str(ADAPTER),
        STACK_NATIVE_IMPL="go",
        STACK_NATIVE_WRAPPER=str(WRAPPER),
        STACK_NATIVE_INVOCATION="n1",
        STACK_NATIVE_CLI_LABEL="status",
        STACK_NATIVE_FRAGMENT="fragment.sh",
        PITHEAD_IMPL="bash",
        _PITHEAD_GO_HYBRID="1",
    )
    fallback = run(["bash", str(reference)], env)
    assert fallback.returncode == 2
    assert not marker.exists()


def test_result_trace_write_failure_overrides_native_status(tmp_path):
    native = tmp_path / "native"
    native.write_text(
        "#!/bin/sh\n"
        'mv "$STACK_NATIVE_LOG" "$STACK_NATIVE_LOG.saved"\n'
        'mkdir "$STACK_NATIVE_LOG"\n'
        "exit 0\n"
    )
    native.chmod(0o755)
    env, trace = selected_env(tmp_path, native)
    result = run([str(WRAPPER), "status"], env)
    assert result.returncode == 2
    assert trace.is_dir()
    assert (tmp_path / "native.trace.saved").read_text().startswith("dispatch\t")


def test_fragment_trace_write_failures_stop_or_override_source(tmp_path):
    lib, fragment = fixture(tmp_path, 'touch "$FRAGMENT_MARKER"\n')
    native = tmp_path / "native"
    native.write_text("#!/bin/sh\nexit 0\n")
    native.chmod(0o755)
    env, trace = selected_env(tmp_path, native)
    marker = tmp_path / "fragment-ran"
    env["FRAGMENT_MARKER"] = str(marker)
    trace.mkdir()
    initial = run(["bash", "-c", 'source "$1"; source "$2"', "_", str(lib), str(fragment)], env)
    assert initial.returncode == 2
    assert not marker.exists()

    direct = run(["bash", str(fragment)], env)
    assert direct.returncode == 2
    assert not marker.exists()

    trace.rmdir()
    fragment.write_text(
        'mv "$STACK_NATIVE_LOG" "$STACK_NATIVE_LOG.saved"\nmkdir "$STACK_NATIVE_LOG"\ntrue\n'
    )
    completed = run(
        ["bash", "-c", 'source "$1"; source "$2"; true', "_", str(lib), str(fragment)], env
    )
    assert completed.returncode == 2
    assert trace.is_dir()
    assert (tmp_path / "native.trace.saved").read_text().startswith("visit\t")


def test_wrapper_preserves_closed_stdout_status(tmp_path):
    native = tmp_path / "native"
    native.write_text("#!/bin/sh\nprintf x\nexit $?\n")
    native.chmod(0o755)
    env, _ = selected_env(tmp_path, native)
    direct = run(["bash", "-c", 'exec 1>&-; exec "$1"', "_", str(native)], env)
    traced = run(["bash", "-c", 'exec 1>&-; exec "$1"', "_", str(WRAPPER)], env)
    assert direct.returncode == 1
    assert traced.returncode == direct.returncode


def test_wrapper_preserves_inherited_ignored_signals(tmp_path):
    native = tmp_path / "native"
    native.write_text('#!/usr/bin/env bash\ntrap -p PIPE TERM >"$STACK_NATIVE_SIGNAL_OUTPUT"\n')
    native.chmod(0o755)
    direct_output = tmp_path / "direct.signals"
    traced_output = tmp_path / "traced.signals"
    env, _ = selected_env(tmp_path, native)
    env["STACK_NATIVE_SIGNAL_OUTPUT"] = str(direct_output)
    direct = run(["bash", "-c", 'trap "" PIPE TERM; exec "$1"', "_", str(native)], env)
    env["STACK_NATIVE_SIGNAL_OUTPUT"] = str(traced_output)
    traced = run(["bash", "-c", 'trap "" PIPE TERM; exec "$1"', "_", str(WRAPPER)], env)
    assert direct.returncode == 0
    assert traced.returncode == direct.returncode
    assert traced_output.read_bytes() == direct_output.read_bytes()


def test_native_status_uses_original_reference_root(tmp_path, native_go_binary):
    install = tmp_path / "install"
    install.mkdir()
    reference = install / "pithead"
    reference.write_text("#!/bin/sh\nexit 93\n")
    reference.chmod(0o755)
    (install / ".env").write_text("COMPOSE_PROFILES=\n")
    model = install / "model.json"
    model.write_text("{}\n")
    binary_directory = tmp_path / "bin"
    binary_directory.mkdir()
    status_fixture = (ROOT / "tests/go-parity/status_fixture.py").read_text()
    for name in ("docker", "podman", "curl", "openssl"):
        executable = binary_directory / name
        executable.write_text("#!/usr/bin/env python3\n" + status_fixture)
        executable.chmod(0o755)
    sleep = binary_directory / "sleep"
    sleep.write_text("#!/bin/sh\nexit 0\n")
    sleep.chmod(0o755)
    reference_capture = tmp_path / "reference.capture"
    native_probe = tmp_path / "native-probe"
    native_probe.write_text(
        "#!/bin/sh\n"
        'printf "%s" "$PITHEAD_GO_REFERENCE" >"$REFERENCE_CAPTURE"\n'
        'exec "$REAL_GO_BINARY" "$@"\n'
    )
    native_probe.chmod(0o755)
    env, trace = selected_env(tmp_path, native_probe)
    env.update(
        PATH=f"{binary_directory}{os.pathsep}{os.environ['PATH']}",
        PITHEAD_GO_REFERENCE=str(reference),
        STACK_NATIVE_FRAGMENT="doctor/test-doctor.sh",
        STATUS_FIXTURE=str(model),
        STATUS_COUNTER=str(install / "counter"),
        PITHEAD_MIGRATION_MARKER_FILE=str(install / "migration"),
        PITHEAD_CMDLINE=str(install / "cmdline"),
        REAL_GO_BINARY=str(native_go_binary),
        REFERENCE_CAPTURE=str(reference_capture),
        NO_COLOR="1",
    )
    (install / "cmdline").write_text("rauc.slot=A\n")
    result = run([str(WRAPPER), "status"], env, cwd=install)
    assert result.returncode == 0, result.stdout + result.stderr
    assert "All expected services are up." in result.stdout
    assert reference_capture.read_text() == str(reference)
    summary = run([str(REPORT), str(trace)], os.environ.copy())
    assert summary.returncode == 0, summary.stdout + summary.stderr
    assert json.loads(summary.stdout)["fragments"]["doctor/test-doctor.sh"] == {
        "dispatches": 1,
        "native_successes": 1,
    }


def test_real_native_fallback_is_traced_once_and_preserves_ignored_signals(
    tmp_path, native_go_binary
):
    reference = tmp_path / "reference"
    reference.write_text(
        "#!/usr/bin/env bash\n"
        'source "$PRELUDE"\n'
        'printf "outer=<%s>\\n" "$PITHEAD_IMPL"\n'
        'bash -c \'printf "nested-shell=<%s>\\n" "$PITHEAD_IMPL"\'\n'
        'bash "$NESTED_CLI" --version\n'
        'trap -p PIPE TERM >"$SIGNAL_OUTPUT"\n'
    )
    reference.chmod(0o755)
    direct_output = tmp_path / "direct.signals"
    traced_output = tmp_path / "traced.signals"
    base = os.environ.copy()
    base.update(
        SIGNAL_OUTPUT=str(direct_output),
        PITHEAD_IMPL="bash",
        PRELUDE=str(ROOT / "lib/pithead/00-prelude.sh"),
        NESTED_CLI=str(ROOT / "pithead"),
    )
    direct = run(["bash", "-c", 'trap "" PIPE TERM; exec "$1"', "_", str(reference)], base)
    assert direct.returncode == 0, direct.stdout + direct.stderr
    env, trace = selected_env(tmp_path, native_go_binary)
    env.update(
        PITHEAD_GO_REFERENCE=str(reference),
        STACK_NATIVE_FRAGMENT="fragment.sh",
        SIGNAL_OUTPUT=str(traced_output),
        _PITHEAD_GO_IGNORED_SIGNALS="13,15",
        PRELUDE=str(ROOT / "lib/pithead/00-prelude.sh"),
        NESTED_CLI=str(ROOT / "pithead"),
    )
    traced = run(["bash", "-c", 'trap "" PIPE TERM; exec "$1" unknown', "_", str(WRAPPER)], env)
    assert traced.returncode == 0, traced.stdout + traced.stderr
    assert traced.stdout == direct.stdout
    assert "outer=<bash>" in traced.stdout
    assert "nested-shell=<bash>" in traced.stdout
    assert traced_output.read_bytes() == direct_output.read_bytes()
    summary = run([str(REPORT), str(trace)], os.environ.copy())
    assert summary.returncode == 0, summary.stdout + summary.stderr
    assert json.loads(summary.stdout)["fragments"]["fragment.sh"] == {
        "dispatches": 1,
        "reference_fallbacks": 1,
    }


def test_strict_report_catches_supported_helper_source_mutation(tmp_path):
    binary = mutated_keep_running_binary(tmp_path)
    env, trace = selected_env(tmp_path, binary)
    env.update(
        STACK_NATIVE_FRAGMENT="lifecycle/keep-running.sh", PITHEAD_GO_HELPER="keep-running-scope"
    )
    assert run([str(WRAPPER)], env).returncode == 125
    document = tmp_path / "config.json"
    document.write_text("{}\n")
    reference = tmp_path / "reference"
    reference.write_text(
        "#!/usr/bin/env bash\n"
        'source "$STACK_NATIVE_PRELUDE"\n'
        'PITHEAD_GO_HELPER=config-document "$_pithead_go_hybrid_binary" '
        '"$STACK_NATIVE_DOCUMENT" config\n'
    )
    reference.chmod(0o755)
    env.pop("PITHEAD_GO_HELPER")
    env.update(
        PITHEAD_GO_REFERENCE=str(reference),
        STACK_NATIVE_DOCUMENT=str(document),
        STACK_NATIVE_PRELUDE=str(ROOT / "lib/pithead/00-prelude.sh"),
    )
    assert run([str(WRAPPER), "unknown"], env).returncode == 0
    strict = run(
        [str(REPORT), "--require-native", "keep-running-scope", str(trace)], os.environ.copy()
    )
    assert strict.returncode == 1
    assert "keep-running-scope" in strict.stdout
    parsed = json.loads(strict.stdout.split("required helpers without native success:", 1)[0])
    assert parsed["fragments"]["lifecycle/keep-running.sh"] == {
        "compatibility_fallbacks": 1,
        "dispatches": 3,
        "native_successes": 1,
        "reference_fallbacks": 1,
    }
    assert parsed["helpers"]["config-document"] == {"native_successes": 1}
