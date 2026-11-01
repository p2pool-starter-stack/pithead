import os
import shutil
import subprocess
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
ADAPTER = ROOT / "tests/go-parity/lifecycle_options_reference.sh"
GO_BINARY = ROOT / "go/bin/pithead"
BASH = shutil.which("bash")
if BASH is None:
    raise RuntimeError("bash is required")
SEEDS = (b"seed-yes", b"seed-dry", b"seed-porcelain", b"seed-arg")


class LifecycleOptionsParityTests(unittest.TestCase):
    def setUp(self):
        cache = ROOT / ".go-cache/tmp"
        cache.mkdir(parents=True, exist_ok=True)
        self.scratch = tempfile.TemporaryDirectory(dir=cache)
        self.addCleanup(self.scratch.cleanup)
        self.directory = Path(self.scratch.name)
        self.values = self.directory / "values"
        self.calls = self.directory / "calls"
        self.state = self.directory / "state"
        self.capture = self.directory / "capture"
        self.argc = self.directory / "argc"
        self.native = self.directory / "native"
        self.reply = self.directory / "reply"

    def environment(self, implementation, extra=None):
        env = {key: value for key, value in os.environ.items() if not key.startswith("PITHEAD_")}
        env.pop("BASH_ENV", None)
        env.update(
            LIFECYCLE_OPTIONS_IMPL=implementation,
            LIFECYCLE_OPTIONS_CALLS=str(self.calls),
            LIFECYCLE_OPTIONS_STATE=str(self.state),
            LIFECYCLE_OPTIONS_NATIVE=str(self.native),
            PITHEAD_GO_BINARY=str(GO_BINARY),
            LC_ALL="C",
        )
        env.update(extra or {})
        return env

    def invoke(self, implementation, args, *, operation="main", extra=None):
        self.values.write_bytes(
            b"".join((v.encode() if isinstance(v, str) else v) + b"\0" for v in args)
        )
        self.calls.write_bytes(b"")
        self.state.unlink(missing_ok=True)
        self.native.unlink(missing_ok=True)
        result = subprocess.run(  # noqa: S603
            [BASH, str(ADAPTER), str(ROOT), operation, str(self.values)],
            env=self.environment(implementation, extra),
            capture_output=True,
            check=False,
            timeout=15,
        )
        self.assertTrue(self.state.is_file())
        fields = self.state.read_bytes().split(b"\0")
        self.assertEqual((len(fields), fields[-1]), (5, b""))
        return result, self.calls.read_bytes().splitlines(), tuple(fields[:-1])

    def compare(self, args, *, operation="main", extra=None, selected_extra=None):
        baseline = self.invoke("bash", args, operation=operation, extra=extra)
        selected = self.invoke(
            "go", args, operation=operation, extra={**(extra or {}), **(selected_extra or {})}
        )
        self.assertEqual(
            (selected[0].returncode, selected[0].stdout, selected[0].stderr, selected[1:]),
            (baseline[0].returncode, baseline[0].stdout, baseline[0].stderr, baseline[1:]),
            args,
        )
        return selected

    def fake_helper(self, body):
        helper = self.directory / "helper"
        helper.write_text(
            "#!/usr/bin/env bash\nset -eu\n"
            'test "${PITHEAD_GO_HELPER:-}" = lifecycle-options || exit 125\n' + body
        )
        helper.chmod(0o755)
        return helper

    def spy(self):
        return self.fake_helper(
            'printf "%s\\n" "$#" >"$LIFECYCLE_OPTIONS_ARGC"\n'
            '/bin/cat >"$LIFECYCLE_OPTIONS_CAPTURE"\n'
            '"$LIFECYCLE_OPTIONS_REAL_GO" <"$LIFECYCLE_OPTIONS_CAPTURE" >"$LIFECYCLE_OPTIONS_REPLY"\n'
            '/bin/cat "$LIFECYCLE_OPTIONS_REPLY"\n'
        )

    def spy_env(self, binary):
        return {
            "PITHEAD_GO_BINARY": str(binary),
            "LIFECYCLE_OPTIONS_ARGC": str(self.argc),
            "LIFECYCLE_OPTIONS_CAPTURE": str(self.capture),
            "LIFECYCLE_OPTIONS_REAL_GO": str(GO_BINARY),
            "LIFECYCLE_OPTIONS_TRACE_NATIVE": "1",
            "LIFECYCLE_OPTIONS_REPLY": str(self.reply),
        }

    def test_no_options_verbs_preserve_rejection_and_callback_order(self):
        for verb in ("render", "up", "down"):
            with self.subTest(verb=verb):
                result, calls, state = self.compare([verb])
                self.assertEqual(result.returncode, 71)
                self.assertEqual(
                    calls,
                    [b"provenance"] + ([b"deployed"] if verb == "up" else []) + [verb.encode()],
                )
                self.assertEqual(state, SEEDS)
            for argument in ("--yes", "--", "", "positional"):
                with self.subTest(verb=verb, argument=argument):
                    result, calls, state = self.compare([verb, argument, "ignored"])
                    self.assertEqual((result.returncode, calls, state), (1, [b"provenance"], SEEDS))
                    self.assertIn(f"Unknown option for {verb}:".encode(), result.stderr)

    def test_apply_flags_and_repeats_preserve_local_state(self):
        cases = [
            ([], (b"0", b"0", b"0", b"__unset__")),
            (["-y"], (b"1", b"0", b"0", b"-y")),
            (["--yes", "-y"], (b"1", b"0", b"0", b"-y")),
            (["--dry-run"], (b"0", b"1", b"0", b"--dry-run")),
            (["--porcelain", "--dry-run"], (b"0", b"1", b"1", b"--dry-run")),
            (["--dry-run", "--porcelain", "--yes"], (b"1", b"1", b"1", b"--yes")),
            (["--dry-run", "--dry-run", "--porcelain", "-y"], (b"1", b"1", b"1", b"-y")),
        ]
        for arguments, expected in cases:
            with self.subTest(arguments=arguments):
                result, calls, state = self.compare(["apply", *arguments])
                self.assertEqual(
                    (result.returncode, calls, state), (71, [b"provenance", b"env"], expected)
                )

    def test_apply_errors_preserve_prefix_flags_before_require_env(self):
        cases = [
            (["--porcelain"], (b"0", b"0", b"1", b"--porcelain")),
            (["--porcelain", "--yes"], (b"1", b"0", b"1", b"--yes")),
            (["--yes", "--bad", "--dry-run"], (b"1", b"0", b"0", b"--bad")),
            (["--porcelain", "--bad"], (b"0", b"0", b"1", b"--bad")),
            (["--"], (b"0", b"0", b"0", b"--")),
            ([""], (b"0", b"0", b"0", b"")),
        ]
        for arguments, expected in cases:
            with self.subTest(arguments=arguments):
                result, calls, state = self.compare(["apply", *arguments])
                self.assertEqual((result.returncode, calls, state), (1, [b"provenance"], expected))
                self.assertIn(b"[ERROR]", result.stderr)

    def test_restart_first_target_and_ignored_extra_arguments(self):
        for arguments in ([], ["tor"], ["monerod"], ["", "--bad"], ["tor", "ignored", "--bad"]):
            with self.subTest(arguments=arguments):
                result, calls, state = self.compare(["restart", *arguments])
                self.assertEqual(
                    (result.returncode, calls, state),
                    (71, [b"provenance", b"deployed", b"lock:restart"], SEEDS),
                )
        for arguments in (["wrong"], ["--yes", "tor"]):
            result, calls, state = self.compare(["restart", *arguments])
            self.assertEqual(
                (result.returncode, calls, state), (1, [b"provenance", b"deployed"], SEEDS)
            )
            self.assertIn(b"restart takes no argument", result.stderr)

    def test_help_chains_and_deployment_checks_precede_native_options(self):
        spy = self.spy()
        for arguments, code, calls in [
            (["apply", "--bad", "-h"], 0, []),
            (["restart", "wrong", "--help"], 0, []),
            (["apply", "down"], 72, [b"chain"]),
        ]:
            self.capture.unlink(missing_ok=True)
            result, actual_calls, _ = self.compare(arguments, selected_extra=self.spy_env(spy))
            self.assertEqual((result.returncode, actual_calls), (code, calls))
            self.assertFalse(self.capture.exists())
        self.capture.unlink(missing_ok=True)
        result, calls, _ = self.compare(
            ["restart", "wrong"],
            extra={"LIFECYCLE_OPTIONS_FAIL_DEPLOYED": "1"},
            selected_extra=self.spy_env(spy),
        )
        self.assertEqual((result.returncode, calls), (1, [b"provenance", b"deployed"]))
        self.assertFalse(self.capture.exists())

    def test_shared_reject_helper_retains_other_verbs(self):
        spy = self.spy()
        for arguments in (
            ["apply", "--yes"],
            ["restart", "tor"],
            ["upgrade", "--yes"],
            ["doctor", ""],
            ["status"],
        ):
            with self.subTest(arguments=arguments):
                self.capture.unlink(missing_ok=True)
                result, calls, state = self.compare(
                    arguments, operation="reject", selected_extra=self.spy_env(spy)
                )
                self.assertEqual(
                    (result.returncode, calls, state), (0 if len(arguments) == 1 else 1, [], SEEDS)
                )
                self.assertFalse(self.capture.exists())

    def test_missing_partial_or_malformed_helpers_fall_back_before_assignment(self):
        args = ["apply", "--bad", "--dry-run"]
        self.compare(args, selected_extra={"PITHEAD_GO_BINARY": str(self.directory / "missing")})
        self.compare(args, selected_extra={"LIFECYCLE_OPTIONS_WITHOUT_HOOK": "1"})
        for body in [
            "printf 'hidden error\\n' >&2; exit 91\n",
            "printf 'ok\\0\\0'\n",
            "printf '%s\\0' ok '' 1\n",
            "printf '%s\\0' unknown-kind '' 1 1 1\n",
            "printf '%s\\0' ok '' 2 0 0\n",
            "printf '%s\\0' ok '' 1 1 1 extra\n",
            "printf '%s\\0' ok '' 1 1 1; exit 91\n",
        ]:
            with self.subTest(body=body):
                self.compare(
                    args, selected_extra={"PITHEAD_GO_BINARY": str(self.fake_helper(body))}
                )

    def test_internal_marker_sends_arguments_only_on_stdin(self):
        spy = self.spy()
        extra = self.spy_env(spy)
        extra["PITHEAD_GO_CONFIG_DOCUMENT_BINARY"] = extra.pop("PITHEAD_GO_BINARY")
        result, calls, state = self.invoke("bash", ["apply", "--yes", "--dry-run"], extra=extra)
        self.assertEqual(
            (result.returncode, calls, state),
            (71, [b"provenance", b"env"], (b"1", b"1", b"0", b"--dry-run")),
        )
        self.assertEqual(self.argc.read_text(), "0\n")
        self.assertEqual(self.capture.read_bytes(), b"apply\x002\x00--yes\x00--dry-run\x000\x00")

    def test_go_selection_handles_each_native_option_boundary(self):
        spy = self.spy()
        for args, kind in (
            (["render"], b"ok"),
            (["up"], b"ok"),
            (["down"], b"ok"),
            (["apply", "--dry-run", "--porcelain"], b"ok"),
            (["restart", "monerod", "ignored"], b"ok"),
            (["render", "--bad"], b"unknown"),
            (["apply", "--bad"], b"unknown"),
            (["apply", "--porcelain"], b"porcelain-needs-dry-run"),
            (["restart", "wrong"], b"unknown"),
        ):
            with self.subTest(args=args):
                result, _, _ = self.compare(args, selected_extra=self.spy_env(spy))
                self.assertEqual(result.returncode, 71 if kind == b"ok" else 1)
                if kind == b"ok":
                    self.assertEqual(self.native.read_text(), f"{args[0]}:0\n")
                self.assertEqual(self.reply.read_bytes().split(b"\0")[0], kind)
                self.assertEqual(self.argc.read_text(), "0\n")
                fields = [args[0], str(len(args) - 1), *args[1:], "0"]
                self.assertEqual(
                    self.capture.read_bytes(), b"".join(value.encode() + b"\0" for value in fields)
                )

    def test_literal_control_and_non_utf8_arguments_preserve_error_bytes(self):
        for args in (
            [b"apply", b"--bad\xff"],
            ["render", "--bad\\nnext"],
            ["restart", "wrong\nvalue"],
            ["apply", "--😈"],
        ):
            with self.subTest(args=args):
                result, _, _ = self.compare(args)
                self.assertEqual(result.returncode, 1)


if __name__ == "__main__":
    if not GO_BINARY.is_file():
        raise SystemExit("run make go-build first")
    unittest.main()
