"""Caddy diagnostics must distinguish failure causes without printing config values."""

import importlib.util
import json
import sys
import unittest
from pathlib import Path
from unittest.mock import mock_open, patch

spec = importlib.util.spec_from_file_location(
    "caddy_evidence", Path(__file__).with_name("caddy-failure-evidence.py")
)
evidence = importlib.util.module_from_spec(spec)
spec.loader.exec_module(evidence)


class CaddyEvidenceTests(unittest.TestCase):
    def test_config_keeps_line_numbers_and_no_values(self):
        shape = evidence.config_shape(
            "https://private.invalid {\n bind secret-address\n basic_auth {\n"
            " secret-user secret-hash\n }\n tls secret-cert secret-key\n"
            " reverse_proxy secret-upstream {\n }\n}\n"
        )
        self.assertEqual(
            shape["lines"],
            [
                {"line": 1, "directive": "value", "tokens": 2},
                {"line": 2, "directive": "bind", "tokens": 2},
                {"line": 3, "directive": "basic_auth", "tokens": 2},
                {"line": 4, "directive": "value", "tokens": 2},
                {"line": 5, "directive": "}", "tokens": 1},
                {"line": 6, "directive": "tls", "tokens": 3},
                {"line": 7, "directive": "reverse_proxy", "tokens": 3},
                {"line": 8, "directive": "}", "tokens": 1},
                {"line": 9, "directive": "}", "tokens": 1},
            ],
        )
        self.assertNotIn("secret", json.dumps(shape))
        self.assertNotIn("private.invalid", json.dumps(shape))
        self.assertFalse(shape["truncated"])
        self.assertTrue(evidence.config_shape("bind secret\n" * 201)["truncated"])
        self.assertEqual(len(evidence.config_shape("bind secret\n" * 201)["lines"]), 200)

    def test_daemon_errors_include_stderr_and_no_free_text(self):
        for phrase in evidence.ERRORS:
            with self.subTest(phrase=phrase):
                line = f"Error: Caddyfile:17: {phrase}: secret-hash private.invalid"
                row = evidence.log_shape(line)[0]
                self.assertIn(phrase, row["phrases"])
                self.assertEqual(row["config_line"], 17)
                self.assertNotIn("secret", json.dumps(row))
                self.assertNotIn("private.invalid", json.dumps(row))
        row = evidence.log_shape(
            '{"level":"error","msg":"loading initial config",'
            '"error":"listen tcp secret-address: cannot assign requested address",'
            '"password":"secret-password"}'
        )[0]
        self.assertEqual(row["level"], "error")
        self.assertEqual(
            row["phrases"], ["cannot assign requested address", "loading initial config"]
        )
        self.assertNotIn("secret", json.dumps(row))
        for text in ("[]", "null", '"secret"', '{"level":"secret","msg":"secret"}'):
            row = evidence.log_shape(text)[0]
            self.assertEqual(row["level"], "unknown")
            self.assertEqual(row["phrases"], [])
        self.assertEqual(len(evidence.log_shape("secret\n" * 100)), 40)

    def test_state_excludes_error_and_health_log(self):
        state = evidence.state_shape(
            json.dumps(
                {
                    "Running": False,
                    "Restarting": True,
                    "OOMKilled": False,
                    "ExitCode": 1,
                    "Status": "exited",
                    "Error": "secret",
                    "Health": {"Log": ["secret"]},
                }
            )
        )
        self.assertEqual(
            state,
            {
                "available": True,
                "Running": False,
                "Restarting": True,
                "OOMKilled": False,
                "ExitCode": 1,
                "Status": "exited",
            },
        )
        for text in ("[]", "null", "not-json"):
            self.assertEqual(evidence.state_shape(text), {"available": False})
        self.assertEqual(
            evidence.state_shape('{"Running":"secret","ExitCode":true}'), {"available": True}
        )

    def test_snapshot_keeps_probe_verdicts_and_no_secrets(self):
        with (
            patch.object(
                evidence,
                "probe",
                side_effect=[
                    (0, '{"ExitCode":1}', False),
                    (0, "Error: permission denied secret", True),
                ],
            ) as probe,
            patch.object(Path, "open", mock_open(read_data=b"bind secret\n")),
        ):
            snapshot = evidence.snapshot()
        self.assertEqual(snapshot["state"]["ExitCode"], 1)
        self.assertEqual(snapshot["log"][0]["phrases"], ["permission denied"])
        self.assertTrue(snapshot["config"]["available"])
        self.assertTrue(snapshot["log_truncated"])
        self.assertFalse(snapshot["state_truncated"])
        self.assertNotIn("secret", json.dumps(snapshot))
        self.assertEqual(probe.call_args_list[0].args, ("state",))
        self.assertEqual(probe.call_args_list[1].args, ("log",))
        self.assertEqual(
            evidence.COMMANDS,
            {
                "state": ["/usr/bin/podman", "inspect", "caddy", "--format", "{{json .State}}"],
                "log": ["/usr/bin/podman", "logs", "--tail", "40", "caddy"],
            },
        )

    def test_real_capture_bounds_bytes_and_merges_stderr(self):
        with patch.dict(
            evidence.COMMANDS,
            {
                "log": [
                    sys.executable,
                    "-c",
                    "import sys; sys.stderr.write('permission denied\\n'); sys.exit(3)",
                ]
            },
        ):
            rc, text, truncated = evidence.probe("log")
        self.assertEqual((rc, text, truncated), (3, "permission denied\n", False))
        with patch.dict(
            evidence.COMMANDS,
            {"log": [sys.executable, "-c", "import sys; sys.stdout.write('x'*1000000)"]},
        ):
            rc, text, truncated = evidence.probe("log")
        self.assertEqual(len(text), 65536)
        self.assertTrue(truncated)
        with patch.dict(
            evidence.COMMANDS, {"log": [sys.executable, "-c", "import time; time.sleep(5)"]}
        ):
            rc, text, truncated = evidence.probe("log", seconds=0.05)
        self.assertEqual((rc, text, truncated), (124, "", False))

    def test_unavailable_probes_are_explicit(self):
        with (
            patch.object(evidence.subprocess, "Popen", side_effect=OSError()),
            patch.object(Path, "open", side_effect=OSError()),
        ):
            snapshot = evidence.snapshot()
        self.assertEqual(snapshot["state_exit"], 127)
        self.assertEqual(snapshot["log_exit"], 127)
        self.assertFalse(snapshot["state"]["available"])
        self.assertFalse(snapshot["config"]["available"])


if __name__ == "__main__":
    unittest.main()
