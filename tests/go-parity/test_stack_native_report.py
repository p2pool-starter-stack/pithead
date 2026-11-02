import json
import os
import sys
from pathlib import Path

# ruff: noqa: S101, S603

sys.path.insert(0, str(Path(__file__).resolve().parent))
from test_stack_native_adapter import REPORT, WRAPPER, fixture, run, selected_env  # noqa: E402


def test_report_includes_fragment_with_no_go_dispatches(tmp_path):
    lib, fragment = fixture(tmp_path, "return 0\n")
    native = tmp_path / "native"
    native.write_text("#!/bin/sh\nexit 0\n")
    native.chmod(0o755)
    env, trace = selected_env(tmp_path, native)
    result = run(
        ["bash", "-c", 'source "$1"; source "$2"; true', "_", str(lib), str(fragment)], env
    )
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
