import os
import shutil
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
GO_BINARY = ROOT / "go/bin/pithead"
ADAPTER = ROOT / "tests/go-parity/config_input_reference.sh"
BASH = shutil.which("bash")
if BASH is None:
    raise RuntimeError("bash is required")


class ConfigInputParityTests(unittest.TestCase):
    def setUp(self):
        cache = ROOT / ".go-cache/tmp"
        cache.mkdir(parents=True, exist_ok=True)
        self.scratch = tempfile.TemporaryDirectory(dir=cache)
        self.addCleanup(self.scratch.cleanup)
        self.directory = Path(self.scratch.name)
        self.config = self.directory / "config.json"
        self.trace = self.directory / "trace"

    def environment(self, implementation, **updates):
        env = {key: value for key, value in os.environ.items() if not key.startswith("PITHEAD_")}
        env.pop("BASH_ENV", None)
        env.update(
            CONFIG_INPUT_PARITY_IMPL=implementation,
            PITHEAD_GO_BINARY=str(GO_BINARY),
            NO_COLOR="1",
        )
        env.update(updates)
        return env

    def invoke(
        self, implementation, raw, scenario="normal", env=None, config=None, config_argument=None
    ):
        target = config or self.config
        if raw is None:
            pass
        elif isinstance(raw, bytes):
            target.write_bytes(raw)
        else:
            target.write_text(raw)
        self.trace.unlink(missing_ok=True)
        result = subprocess.run(  # noqa: S603
            [
                BASH,
                str(ADAPTER),
                str(ROOT),
                config_argument or str(target),
                str(self.trace),
                scenario,
            ],
            cwd=self.directory,
            env=self.environment(implementation, **(env or {})),
            capture_output=True,
            check=False,
            timeout=15,
        )
        trace = self.trace.read_text().splitlines() if self.trace.exists() else []
        return result, trace

    def assert_parity(self, raw, expected_trace=None):
        baseline, baseline_trace = self.invoke("bash", raw)
        selected, selected_trace = self.invoke("go", raw)
        self.assertEqual(
            (selected.returncode, selected.stdout, selected.stderr),
            (baseline.returncode, baseline.stdout, baseline.stderr),
            raw,
        )
        if expected_trace is not None:
            self.assertEqual(selected_trace, expected_trace)
        return baseline_trace, selected_trace, selected

    def test_supported_gate_order_and_first_error(self):
        cases = [
            (b'{"a":1,"a":2,"notifications":{"webhooks":false},"v":"a\\nb"}', "document"),
            (b'{"password":"PASTE_secret","notifications":{"webhooks":false}}', "document"),
            (b'{"notifications":{"webhooks":false},"v":"a\\nb"}', "webhooks"),
            (b'{"notifications":{"webhooks":[]},"v":"a\\nb"}', "controls"),
            (b'{"notifications":{"webhooks":[]},"v":"safe"}', "ok"),
        ]
        for raw, stage in cases:
            with self.subTest(stage=stage):
                selected_expected = ["next"] if stage == "ok" else []
                baseline_trace, selected_trace, result = self.assert_parity(raw, selected_expected)
                expected = {
                    "document": ["document"],
                    "webhooks": ["document", "webhooks"],
                    "controls": ["document", "webhooks", "controls"],
                    "ok": ["document", "webhooks", "controls", "next"],
                }[stage]
                self.assertEqual(baseline_trace, expected)
                if stage == "ok":
                    self.assertEqual(result.returncode, 71)
                    self.assertEqual(selected_trace, ["next"])

    def test_syntax_failure_is_native_and_precedes_later_gates(self):
        baseline_trace, selected_trace, result = self.assert_parity(b'{"v":', [])
        self.assertEqual(baseline_trace, ["document"])
        self.assertEqual(selected_trace, [])
        self.assertIn(b"Invalid configuration: not valid JSON.", result.stderr)

    def test_secret_values_never_reach_diagnostics(self):
        secrets = [
            (
                b'{"secret\\"path":"YOUR_extremely-private"}',
                b"extremely-private",
                b'secret"path',
            ),
            (b'{"nested":{"bot_token":"line\\nprivate-token"}}', b"private-token", None),
        ]
        for raw, secret, escaped_path in secrets:
            with self.subTest(raw=raw):
                _, _, result = self.assert_parity(raw, [])
                self.assertNotIn(secret, result.stdout + result.stderr)
                if escaped_path is not None:
                    self.assertIn(escaped_path, result.stderr)

    def test_compatibility_inputs_use_legacy_gates(self):
        cases = [
            b'{"value":"\\ud83d\\ude00"}',
            b'{"value":"\\ud800"}',
            b'{"notifications":false}',
            b"[]",
            b'{"value":NaN}',
            b'{"value":"\xff"}',
            b'{"value":' + b"9" * 4097 + b"}",
            b"[" * 129 + b"0" + b"]" * 129,
        ]
        for raw in cases:
            with self.subTest(raw=raw[:40]):
                baseline_trace, selected_trace, _ = self.assert_parity(raw)
                self.assertEqual(selected_trace, baseline_trace)
                self.assertTrue(selected_trace)

    def test_eligibility_fallbacks_match_reference(self):
        raw = b'{"notifications":{"webhooks":[]},"v":"safe"}'
        missing = self.directory / "missing-pithead"
        baseline, baseline_trace = self.invoke("bash", raw)
        selected, selected_trace = self.invoke("go", raw, env={"PITHEAD_GO_BINARY": str(missing)})
        self.assertEqual(
            (selected.returncode, selected.stdout, selected.stderr, selected_trace),
            (baseline.returncode, baseline.stdout, baseline.stderr, baseline_trace),
        )

        for absent in ("python3", "jq", "cat"):
            with self.subTest(absent=absent):
                tool_path = self.tool_path_without(absent)
                baseline, baseline_trace = self.invoke(
                    "bash",
                    raw,
                    f"missing-{absent.removesuffix('3')}",
                    {"CONFIG_INPUT_TOOL_PATH": tool_path},
                )
                selected, selected_trace = self.invoke(
                    "go",
                    raw,
                    f"missing-{absent.removesuffix('3')}",
                    {"CONFIG_INPUT_TOOL_PATH": tool_path},
                )
                self.assertEqual(
                    (selected.returncode, selected.stdout, selected.stderr, selected_trace),
                    (baseline.returncode, baseline.stdout, baseline.stderr, baseline_trace),
                )

    def tool_path_without(self, absent):
        tools = self.directory / f"without-{absent}"
        tools.mkdir(exist_ok=True)
        for name in ("cat", "jq", "python3"):
            source = shutil.which(name)
            if name != absent and source is not None:
                (tools / name).symlink_to(source)
        return str(tools)

    def test_nonregular_and_dash_paths_fall_back(self):
        directory_config = self.directory / "config-directory"
        directory_config.mkdir()
        dash_config = self.directory / "-config.json"
        dash_config.write_bytes(b"{}")
        cases = [
            (directory_config, None, None),
            (dash_config, None, "-config.json"),
        ]
        for target, raw, argument in cases:
            with self.subTest(target=target.name):
                baseline, baseline_trace = self.invoke(
                    "bash", raw, config=target, config_argument=argument
                )
                selected, selected_trace = self.invoke(
                    "go", raw, config=target, config_argument=argument
                )
                self.assertEqual(
                    (selected.returncode, selected.stdout, selected.stderr, selected_trace),
                    (baseline.returncode, baseline.stdout, baseline.stderr, baseline_trace),
                )

        unreadable = self.directory / "unreadable.json"
        unreadable.write_bytes(b"{}")
        unreadable.chmod(0)
        baseline, baseline_trace = self.invoke("bash", None, config=unreadable)
        selected, selected_trace = self.invoke("go", None, config=unreadable)
        self.assertEqual(
            (selected.returncode, selected.stdout, selected.stderr),
            (baseline.returncode, baseline.stdout, baseline.stderr),
        )
        if unreadable.is_file() and os.access(unreadable, os.R_OK):
            self.assertEqual(selected_trace, ["next"])
            self.assertEqual(baseline_trace, ["document", "webhooks", "controls", "next"])
        else:
            self.assertEqual(selected_trace, baseline_trace)
            self.assertEqual(selected_trace, ["document"])

    def test_producer_failure_falls_back_before_public_output(self):
        raw = b'{"notifications":{"webhooks":[]}}'
        baseline, baseline_trace = self.invoke("bash", raw, "producer-failure")
        selected, selected_trace = self.invoke("go", raw, "producer-failure")
        self.assertEqual(
            (selected.returncode, selected.stdout, selected.stderr),
            (baseline.returncode, baseline.stdout, baseline.stderr),
        )
        self.assertEqual(baseline_trace, ["document", "webhooks", "controls", "next"])
        self.assertEqual(selected_trace, ["producer", "document", "webhooks", "controls", "next"])

    def fake_helper(self, body):
        helper = self.directory / "fake-pithead"
        helper.write_text(
            "#!/usr/bin/env bash\nset -eu\n"
            'case "${PITHEAD_GO_HELPER:-}" in config-input-validation) ;; *) exit 125 ;; esac\n'
            + body
        )
        helper.chmod(0o755)
        return helper

    def test_malformed_helper_output_falls_back_without_public_noise(self):
        raw = b'{"notifications":{"webhooks":[]}}'
        cases = {
            "partial-failure": "printf 'ok\\0'; exit 91\n",
            "truncated": "printf 'ok\\0'\n",
            "malformed": "printf 'unknown\\0reason\\0'\n",
            "trailing": "printf 'ok\\0\\0extra\\0'\n",
        }
        baseline, baseline_trace = self.invoke("bash", raw)
        for name, body in cases.items():
            with self.subTest(name=name):
                helper = self.fake_helper(body)
                selected, selected_trace = self.invoke(
                    "go", raw, env={"PITHEAD_GO_BINARY": str(helper)}
                )
                self.assertEqual(
                    (selected.returncode, selected.stdout, selected.stderr, selected_trace),
                    (baseline.returncode, baseline.stdout, baseline.stderr, baseline_trace),
                )

    def test_helper_gets_config_only_on_stdin(self):
        capture = self.directory / "capture"
        args = self.directory / "args"
        helper = self.fake_helper(
            'printf "%s\\n" "$#" >"$ARG_CAPTURE"\n'
            "python3 -c 'import pathlib,sys; pathlib.Path(sys.argv[1]).write_bytes(sys.stdin.buffer.read())' \"$STDIN_CAPTURE\"\n"
            "printf 'ok\\0\\0'\n"
        )
        raw = b'{"password":"private-value"}'
        result, trace = self.invoke(
            "go",
            raw,
            env={
                "PITHEAD_GO_BINARY": str(helper),
                "STDIN_CAPTURE": str(capture),
                "ARG_CAPTURE": str(args),
            },
        )
        self.assertEqual((result.returncode, trace), (71, ["next"]))
        self.assertEqual(args.read_text(), "0\n")
        self.assertEqual(capture.read_bytes(), raw + b"\0" + b"0\0")
        self.assertNotIn(b"private-value", result.stdout + result.stderr)


if __name__ == "__main__":
    if not GO_BINARY.is_file():
        sys.exit("run make go-build first")
    unittest.main()
