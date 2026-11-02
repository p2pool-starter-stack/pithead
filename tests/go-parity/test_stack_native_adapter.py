import json
import os
import subprocess
from pathlib import Path

import pytest

# ruff: noqa: S101, S603

ROOT = Path(__file__).resolve().parents[2]
ADAPTER = ROOT / "tests/go-parity/stack_native_env.sh"
WRAPPER = ROOT / "tests/go-parity/stack_native_binary.sh"
REPORT = ROOT / "tests/go-parity/stack_native_report.py"


def run(command, env, cwd=ROOT):
    return subprocess.run(
        command,
        cwd=cwd,
        env=env,
        text=True,
        capture_output=True,
        timeout=120,
        check=False,
    )


def fixture(tmp_path, fragment_body):
    stack = tmp_path / "tests/stack"
    stack.mkdir(parents=True)
    lib = stack / "lib.sh"
    lib.write_text(
        "STACK_SUITE=1\nfor knob in $(compgen -e -X '!PITHEAD_*'); do unset \"$knob\"; done\n"
    )
    fragment = stack / "fragment.sh"
    fragment.write_text(fragment_body)
    return lib, fragment


def selected_env(tmp_path, binary):
    trace = tmp_path / "native.trace"
    env = os.environ.copy()
    env.update(
        BASH_ENV=str(ADAPTER),
        STACK_NATIVE_IMPL="go",
        STACK_NATIVE_BINARY=str(binary),
        STACK_NATIVE_LOG=str(trace),
    )
    return env, trace


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


def test_source_hook_restores_selection_and_preserves_status(tmp_path):
    lib, fragment = fixture(
        tmp_path,
        'test "$PITHEAD_IMPL" = go\n'
        'test "$PITHEAD_GO_BINARY" = "$STACK_NATIVE_WRAPPER"\n'
        'test "$STACK_NATIVE_FRAGMENT" = fragment.sh\n'
        "! export -p | grep -q 'STACK_SUITE='\n"
        'source "$NESTED"\n'
        "return 7\n",
    )
    nested = fragment.parent / "fixtures/nested.sh"
    nested.parent.mkdir()
    nested.write_text('test "$STACK_NATIVE_FRAGMENT" = fragment.sh\n')
    env = os.environ.copy()
    env.update(BASH_ENV=str(ADAPTER), STACK_NATIVE_IMPL="go", NESTED=str(nested))
    result = run(
        [
            "bash",
            "-c",
            'STACK_SUITE=1; source "$1"; source "$2"; rc=$?; '
            'test -z "${STACK_NATIVE_FRAGMENT+x}"; exit "$rc"',
            "_",
            str(lib),
            str(fragment),
        ],
        env,
    )
    assert result.returncode == 7, result.stdout + result.stderr


def test_direct_stack_script_gets_its_own_fragment(tmp_path):
    _, fragment = fixture(
        tmp_path,
        'test "$STACK_NATIVE_FRAGMENT" = fragment.sh\n'
        'test "$PITHEAD_IMPL" = go\n'
        'test "$PITHEAD_GO_BINARY" = "$STACK_NATIVE_WRAPPER"\n',
    )
    env = os.environ.copy()
    env.update(BASH_ENV=str(ADAPTER), STACK_NATIVE_IMPL="go")
    result = run(["bash", str(fragment)], env)
    assert result.returncode == 0, result.stdout + result.stderr


def test_direct_stack_script_overrides_parent_but_bash_c_inherits_it(tmp_path):
    _, fragment = fixture(
        tmp_path,
        'test "$STACK_NATIVE_FRAGMENT" = fragment.sh\n'
        "bash -c 'test \"$STACK_NATIVE_FRAGMENT\" = fragment.sh'\n",
    )
    env = os.environ.copy()
    env.update(BASH_ENV=str(ADAPTER), STACK_NATIVE_IMPL="go", STACK_NATIVE_FRAGMENT="parent.sh")
    result = run(["bash", str(fragment)], env)
    assert result.returncode == 0, result.stdout + result.stderr


def test_nested_stack_fragment_is_traced_directly_and_when_sourced(tmp_path):
    lib, _ = fixture(tmp_path, "true\n")
    fragment = lib.parent / "dashboard/nested/fragment.sh"
    fragment.parent.mkdir(parents=True)
    fragment.write_text('test "$STACK_NATIVE_FRAGMENT" = dashboard/nested/fragment.sh\n')
    native = tmp_path / "native"
    native.write_text("#!/bin/sh\nexit 0\n")
    native.chmod(0o755)
    env, trace = selected_env(tmp_path, native)
    direct = run(["bash", str(fragment)], env)
    assert direct.returncode == 0, direct.stdout + direct.stderr
    sourced = run(["bash", "-c", 'source "$1"; source "$2"', "_", str(lib), str(fragment)], env)
    assert sourced.returncode == 0, sourced.stdout + sourced.stderr
    summary = run([str(REPORT), str(trace)], os.environ.copy())
    assert summary.returncode == 0, summary.stdout + summary.stderr
    assert json.loads(summary.stdout)["fragments"]["dashboard/nested/fragment.sh"] == {
        "source_status_0": 1,
        "unobserved_direct_statuses": 1,
        "visits": 2,
    }


def test_reference_hook_does_not_restore_scrubbed_selector(tmp_path):
    lib, fragment = fixture(tmp_path, 'test -z "${PITHEAD_IMPL+x}"\n')
    env = os.environ.copy()
    env.update(BASH_ENV=str(ADAPTER), STACK_NATIVE_IMPL="", PITHEAD_IMPL="sentinel")
    result = run(["bash", "-c", 'source "$1"; source "$2"', "_", str(lib), str(fragment)], env)
    assert result.returncode == 0, result.stdout + result.stderr


def test_explicit_bash_child_stays_reference_after_lib_and_nested_bash(tmp_path):
    lib, fragment = fixture(
        tmp_path,
        'test -z "${PITHEAD_IMPL+x}"\nbash -c \'test -z "${PITHEAD_IMPL+x}"\'\n',
    )
    native = tmp_path / "native"
    native.write_text("#!/bin/sh\nexit 90\n")
    native.chmod(0o755)
    env, trace = selected_env(tmp_path, native)
    env["PITHEAD_IMPL"] = "bash"
    result = run(
        [
            "bash",
            "-c",
            'test "$PITHEAD_IMPL" = bash; source "$1"; source "$2"',
            "_",
            str(lib),
            str(fragment),
        ],
        env,
    )
    assert result.returncode == 0, result.stdout + result.stderr
    summary = run([str(REPORT), str(trace)], os.environ.copy())
    assert summary.returncode == 0, summary.stdout + summary.stderr
    assert json.loads(summary.stdout)["fragments"]["fragment.sh"] == {
        "source_status_0": 1,
        "visits": 1,
    }


def test_report_includes_fragment_with_no_go_dispatches(tmp_path):
    lib, fragment = fixture(tmp_path, "return 0\n")
    native = tmp_path / "native"
    native.write_text("#!/bin/sh\nexit 0\n")
    native.chmod(0o755)
    env, trace = selected_env(tmp_path, native)
    result = run(["bash", "-c", 'source "$1"; source "$2"', "_", str(lib), str(fragment)], env)
    assert result.returncode == 0, result.stdout + result.stderr
    summary = run([str(REPORT), str(trace)], os.environ.copy())
    assert summary.returncode == 0, summary.stdout + summary.stderr
    assert json.loads(summary.stdout)["fragments"]["fragment.sh"] == {
        "source_status_0": 1,
        "visits": 1,
    }


def test_helper_and_cli_fallback_are_classified(tmp_path):
    native = tmp_path / "native"
    native.write_text(
        "#!/bin/sh\n"
        'if [ -n "${PITHEAD_GO_HELPER:-}" ]; then exit 125; fi\n'
        'test "$PITHEAD_GO_REFERENCE" = "$EXPECTED_REFERENCE" || exit 90\n'
        "unset PITHEAD_GO_REFERENCE\n"
        'PITHEAD_IMPL=bash _PITHEAD_GO_HYBRID=1 exec bash "$EXPECTED_REFERENCE" "$@"\n'
    )
    native.chmod(0o755)
    reference = tmp_path / "reference"
    reference.write_text("#!/bin/sh\nexit 0\n")
    reference.chmod(0o755)
    env, trace = selected_env(tmp_path, native)
    env.update(STACK_NATIVE_FRAGMENT="fragment.sh", PITHEAD_GO_HELPER="config-document")
    helper = run([str(WRAPPER)], env)
    assert helper.returncode == 125
    env.pop("PITHEAD_GO_HELPER")
    env.update(PITHEAD_GO_REFERENCE=str(reference), EXPECTED_REFERENCE=str(reference))
    cli = run([str(WRAPPER), "upgrade"], env)
    assert cli.returncode == 0, cli.stdout + cli.stderr
    summary = run([str(REPORT), str(trace)], os.environ.copy())
    assert summary.returncode == 0, summary.stdout + summary.stderr
    parsed = json.loads(summary.stdout)
    assert parsed["fragments"]["fragment.sh"] == {
        "compatibility_fallbacks": 1,
        "dispatches": 2,
        "reference_fallbacks": 1,
    }
    strict = run(
        [str(REPORT), "--require-native", "config-document", str(trace)], os.environ.copy()
    )
    assert strict.returncode == 1
    assert "config-document" in strict.stdout


def test_strict_report_accepts_helper_with_native_success_and_compatibility(tmp_path):
    native = tmp_path / "native"
    native.write_text(
        '#!/bin/sh\ncase "${1:-}" in unsupported) exit 125 ;; rejected) exit 1 ;; esac\nexit 0\n'
    )
    native.chmod(0o755)
    env, trace = selected_env(tmp_path, native)
    env.update(STACK_NATIVE_FRAGMENT="fragment.sh", PITHEAD_GO_HELPER="config-document")
    assert run([str(WRAPPER)], env).returncode == 0
    assert run([str(WRAPPER), "unsupported"], env).returncode == 125
    assert run([str(WRAPPER), "rejected"], env).returncode == 1
    strict = run(
        [str(REPORT), "--require-native", "config-document", str(trace)], os.environ.copy()
    )
    assert strict.returncode == 0, strict.stdout + strict.stderr
    assert json.loads(strict.stdout)["helpers"]["config-document"] == {
        "compatibility_fallbacks": 1,
        "native_rejections": 1,
        "native_successes": 1,
    }


def test_report_rejects_unpaired_and_mismatched_fragment_events(tmp_path):
    cases = {
        "duplicate-visit": (
            "visit\tv1\tfragment.sh\tfragment\tsource\nvisit\tv1\tfragment.sh\tfragment\tsource\n",
            "duplicate fragment visit",
        ),
        "duplicate-result": (
            "visit\tv1\tfragment.sh\tfragment\tsource\n"
            "visit-result\tv1\tfragment.sh\tfragment\tsource\t0\n"
            "visit-result\tv1\tfragment.sh\tfragment\tsource\t0\n",
            "duplicate fragment result",
        ),
        "orphan-result": (
            "visit-result\tv1\tfragment.sh\tfragment\tsource\t0\n",
            "orphaned fragment results",
        ),
        "mismatched-result": (
            "visit\tv1\tfragment.sh\tfragment\tsource\n"
            "visit-result\tv1\tother.sh\tfragment\tsource\t0\n",
            "mismatched fragment results",
        ),
        "invalid-visit": (
            "visit\tv1\tfragment.sh\tfragment\tunknown\n",
            "invalid fragment visits",
        ),
    }
    for name, (contents, message) in cases.items():
        trace = tmp_path / name
        trace.write_text(contents)
        result = run([str(REPORT), str(trace)], os.environ.copy())
        assert result.returncode == 2
        assert message in result.stderr


def test_report_rejects_mismatched_native_result_metadata(tmp_path):
    trace = tmp_path / "native.trace"
    trace.write_text(
        "dispatch\tn1\tfragment.sh\thelper\tconfig-document\n"
        "result\tn1\tother.sh\thelper\tconfig-document\t0\n"
    )
    result = run([str(REPORT), str(trace)], os.environ.copy())
    assert result.returncode == 2
    assert "mismatched native results" in result.stderr


def test_report_marks_unfinished_source_and_assert_complete_rejects_it(tmp_path):
    trace = tmp_path / "native.trace"
    trace.write_text("visit\tv1\tfragment.sh\tfragment\tsource\n")
    result = run([str(REPORT), str(trace)], os.environ.copy())
    assert result.returncode == 0, result.stdout + result.stderr
    parsed = json.loads(result.stdout)
    assert parsed["completeness"] == {"unfinished_sources": 1}
    assert parsed["fragments"]["fragment.sh"] == {"unfinished_sources": 1, "visits": 1}
    complete = run([str(REPORT), "--assert-complete", str(trace)], os.environ.copy())
    assert complete.returncode == 1
    assert "unfinished sourced fragments" in complete.stdout


def test_direct_fragment_status_requires_outer_suite_evidence(tmp_path):
    trace = tmp_path / "native.trace"
    trace.write_text("visit\tv1\tfragment.sh\tfragment\tdirect\n")
    result = run([str(REPORT), str(trace)], os.environ.copy())
    assert result.returncode == 0, result.stdout + result.stderr
    parsed = json.loads(result.stdout)
    assert parsed["completeness"] == {"unobserved_direct_statuses": 1}
    assert parsed["fragments"]["fragment.sh"] == {
        "unobserved_direct_statuses": 1,
        "visits": 1,
    }
    missing = run([str(REPORT), "--assert-complete", str(trace)], os.environ.copy())
    assert missing.returncode == 1
    assert "direct fragment status requires --suite-exit-status" in missing.stdout
    passing = run(
        [str(REPORT), "--assert-complete", "--suite-exit-status", "0", str(trace)],
        os.environ.copy(),
    )
    assert passing.returncode == 0, passing.stdout + passing.stderr
    failing = run(
        [str(REPORT), "--assert-complete", "--suite-exit-status", "9", str(trace)],
        os.environ.copy(),
    )
    assert failing.returncode == 1
    assert "outer suite failed with status 9" in failing.stdout


def test_assert_complete_rejects_empty_trace(tmp_path):
    trace = tmp_path / "native.trace"
    trace.write_text("")
    result = run([str(REPORT), str(trace)], os.environ.copy())
    assert result.returncode == 0, result.stdout + result.stderr
    assert json.loads(result.stdout)["completeness"] == {"no_fragment_visits": 1}
    complete = run([str(REPORT), "--assert-complete", str(trace)], os.environ.copy())
    assert complete.returncode == 1
    assert "trace has no fragment visits" in complete.stdout


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
    completed = run(["bash", "-c", 'source "$1"; source "$2"', "_", str(lib), str(fragment)], env)
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
