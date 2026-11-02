import json
import os
import subprocess
from pathlib import Path

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


def test_source_hook_preserves_positional_parameter_semantics(tmp_path):
    _, fragment = fixture(
        tmp_path,
        'printf \'inside:%s:%s\\n\' "$#" "$*"\nset -- changed values\nreturn 7\n',
    )
    commands = [
        f'set --; source "{fragment}"; rc=$?; printf "caller:%s:%s:rc=%s\\n" "$#" "$*" "$rc"',
        f'set -- alpha beta; source "{fragment}"; rc=$?; printf "caller:%s:%s:rc=%s\\n" "$#" "$*" "$rc"',
        f'set -- caller; source "{fragment}" explicit one; rc=$?; printf "caller:%s:%s:rc=%s\\n" "$#" "$*" "$rc"',
    ]
    for index, command in enumerate(commands):
        baseline_env = os.environ.copy()
        baseline_env.pop("BASH_ENV", None)
        baseline = run(["bash", "-c", command], baseline_env)
        native = tmp_path / f"native-{index}"
        native.write_text("#!/bin/sh\nexit 0\n")
        native.chmod(0o755)
        traced_env, _ = selected_env(tmp_path / f"trace-{index}", native)
        (tmp_path / f"trace-{index}").mkdir()
        traced = run(["bash", "-c", command], traced_env)
        assert (traced.returncode, traced.stdout, traced.stderr) == (
            baseline.returncode,
            baseline.stdout,
            baseline.stderr,
        )


def test_direct_fragment_restores_go_after_lib_scrub(tmp_path):
    lib, fragment = fixture(tmp_path, "")
    fragment.write_text(
        'HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"\n'
        'source "$HERE/lib.sh"\n'
        'test "$STACK_NATIVE_FRAGMENT" = fragment.sh\n'
        'test "$PITHEAD_IMPL" = go\n'
        'test "$PITHEAD_GO_BINARY" = "$STACK_NATIVE_WRAPPER"\n'
        '"$PITHEAD_GO_BINARY" status\n'
    )
    native = tmp_path / "native"
    native.write_text("#!/bin/sh\nexit 0\n")
    native.chmod(0o755)
    env, trace = selected_env(tmp_path, native)
    result = run(["bash", str(fragment)], env)
    assert result.returncode == 0, result.stdout + result.stderr
    summary = run([str(REPORT), str(trace)], os.environ.copy())
    assert summary.returncode == 0, summary.stdout + summary.stderr
    parsed = json.loads(summary.stdout)
    assert parsed["fragments"]["fragment.sh"]["unobserved_direct_statuses"] == 1
    assert parsed["fragments"]["fragment.sh"]["dispatches"] == 1


def test_nested_stack_fragment_is_traced_directly_and_when_sourced(tmp_path):
    lib, _ = fixture(tmp_path, "true\n")
    fragment = lib.parent / "feature/nested/fragment.sh"
    fragment.parent.mkdir(parents=True)
    fragment.write_text('test "$STACK_NATIVE_FRAGMENT" = feature/nested/fragment.sh\n')
    native = tmp_path / "native"
    native.write_text("#!/bin/sh\nexit 0\n")
    native.chmod(0o755)
    env, trace = selected_env(tmp_path, native)
    direct = run(["bash", str(fragment)], env)
    assert direct.returncode == 0, direct.stdout + direct.stderr
    sourced = run(
        ["bash", "-c", 'source "$1"; source "$2"; true', "_", str(lib), str(fragment)], env
    )
    assert sourced.returncode == 0, sourced.stdout + sourced.stderr
    summary = run([str(REPORT), str(trace)], os.environ.copy())
    assert summary.returncode == 0, summary.stdout + summary.stderr
    assert json.loads(summary.stdout)["fragments"]["feature/nested/fragment.sh"] == {
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
            'test "$PITHEAD_IMPL" = bash; source "$1"; source "$2"; true',
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
