import json
import os
import shutil
import subprocess
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
ADAPTER = ROOT / "tests/go-parity/proxy_settings_reference.sh"
GO_BINARY = ROOT / "go/bin/pithead"
BASH = shutil.which("bash")
if BASH is None:
    raise RuntimeError("bash is required")


class ProxySettingsParityTests(unittest.TestCase):
    def setUp(self):
        self.scratch = tempfile.TemporaryDirectory()
        self.addCleanup(self.scratch.cleanup)
        self.directory = Path(self.scratch.name)
        self.config = self.directory / "config.json"
        self.calls = self.directory / "calls"
        self.marker = self.directory / "jq-called"
        self.tools = self.directory / "bin"
        self.tools.mkdir()
        jq = self.tools / "jq"
        jq.write_text('#!/bin/sh\nprintf called >"$JQ_MARKER"\nexit 91\n')
        jq.chmod(0o755)

    def environment(self, implementation, binary=None, forbid_jq=False, extra=None):
        env = {key: value for key, value in os.environ.items() if not key.startswith("PITHEAD_")}
        env.pop("BASH_ENV", None)
        env.update(
            PROXY_SETTINGS_PARITY_IMPL=implementation,
            PITHEAD_GO_BINARY=str(binary or GO_BINARY),
            PROXY_SETTINGS_CALL_LOG=str(self.calls),
            JQ_MARKER=str(self.marker),
        )
        if forbid_jq:
            env["PATH"] = str(self.tools) + os.pathsep + env.get("PATH", os.defpath)
        env.update(extra or {})
        return env

    def invoke(self, implementation, raw, *, binary=None, forbid_jq=False, extra=None):
        self.config.write_bytes(raw)
        self.calls.write_text("")
        self.marker.unlink(missing_ok=True)
        completed = subprocess.run(  # noqa: S603
            [BASH, str(ADAPTER), str(ROOT), str(self.config)],
            env=self.environment(implementation, binary, forbid_jq, extra),
            capture_output=True,
            check=False,
            timeout=15,
        )
        return completed, self.calls.read_bytes()

    def helper(self, raw, path=None):
        target = path or self.config
        if raw is not None:
            target.write_bytes(raw)
        env = self.environment("go")
        env["PITHEAD_GO_HELPER"] = "config-proxy-settings"
        return subprocess.run(  # noqa: S603
            [str(GO_BINARY), str(target)], env=env, capture_output=True, check=False, timeout=15
        )

    def encoded(self, document):
        return json.dumps(document, ensure_ascii=False, separators=(",", ":")).encode()

    def result(self, completed):
        return completed.returncode, completed.stdout, completed.stderr

    def state(self, completed):
        values = completed.stdout.split(b"\0")
        self.assertEqual(len(values), 5)
        self.assertEqual((values[0], values[-1]), (b"", b""))
        return tuple(value.decode() for value in values[1:-1])

    def compare(self, raw, *, native=False, extra=None):
        baseline, baseline_calls = self.invoke("bash", raw, extra=extra)
        selected, selected_calls = self.invoke("go", raw, forbid_jq=native, extra=extra)
        self.assertEqual(self.result(selected), self.result(baseline))
        self.assertEqual(selected_calls, baseline_calls)
        if native:
            self.assertFalse(self.marker.exists())
        return selected, selected_calls

    def test_supported_settings_match_without_jq(self):
        cases = [
            ({}, ("", "false", "0")),
            ({"p2pool": None, "proxy": None}, ("", "false", "0")),
            (
                {"p2pool": {"stratum_password": False}, "proxy": {"donate_level": False}},
                ("", "false", "0"),
            ),
            (
                {
                    "p2pool": {"stratum_password": "A9._:@-", "stratum_tls": "YES"},
                    "proxy": {"donate_level": "0099"},
                },
                ("A9._:@-", "true", "0099"),
            ),
            (
                {"p2pool": {"stratum_password": "a" * 128}, "proxy": {"donate_level": 99}},
                ("a" * 128, "false", "99"),
            ),
            (
                {
                    "p2pool": {"stratum_password": 12345678, "stratum_tls": 1},
                    "proxy": {"donate_level": "00"},
                },
                ("12345678", "true", "00"),
            ),
            ({"p2pool": {"stratum_password": True, "stratum_tls": "true"}}, ("true", "true", "0")),
            ({"proxy": {"donate_level": "0" * 256}}, ("", "false", "0" * 256)),
            ({"proxy": {"donate_level": "0" * 256 + "99"}}, ("", "false", "0" * 256 + "99")),
        ]
        for value in [False, None, "false", "no", "OFF", "garbage", 0, 2]:
            cases.append(({"p2pool": {"stratum_tls": value}}, ("", "false", "0")))
        for value in [True, "true", "True", "1", "yes", "ON"]:
            cases.append(({"p2pool": {"stratum_tls": value}}, ("", "true", "0")))
        for document, expected in cases:
            with self.subTest(document=document):
                completed, calls = self.compare(self.encoded(document), native=True)
                self.assertEqual(completed.returncode, 0)
                self.assertEqual(self.state(completed), expected)
                self.assertEqual(calls, b"")

    def test_errors_preserve_verdict_order_and_partial_globals(self):
        for password in [
            "bad space",
            "a" * 129,
            'quote"',
            "dollar$",
            "slash/",
            "back\\",
            "unicodeé",
            "semi;",
            "star*",
        ]:
            with self.subTest(password=password):
                completed, _ = self.compare(
                    self.encoded(
                        {
                            "p2pool": {"stratum_password": password, "stratum_tls": []},
                            "proxy": {"donate_level": {}},
                        }
                    ),
                    native=True,
                )
                self.assertEqual(completed.returncode, 1)
                self.assertEqual(self.state(completed), (password, "seed-tls", "seed-donation"))
                self.assertIn(b"p2pool.stratum_password must be", completed.stderr)
        for donation in [
            100,
            -1,
            "",
            "-0",
            " 1",
            "1 ",
            "1.0",
            "0x1",
            "bad",
            True,
            "000100",
            "9223372036854775807",
        ]:
            with self.subTest(donation=donation):
                completed, _ = self.compare(
                    self.encoded(
                        {
                            "p2pool": {"stratum_password": "valid", "stratum_tls": "on"},
                            "proxy": {"donate_level": donation},
                        }
                    ),
                    native=True,
                )
                self.assertEqual(completed.returncode, 1)
                self.assertEqual(self.state(completed)[:2], ("valid", "true"))
                self.assertIn(b"proxy.donate_level must be an integer", completed.stderr)

    def test_auto_and_unsupported_inputs_keep_bash_fallback(self):
        cases = [
            b'{"p2pool":{"stratum_password":"auto","stratum_tls":true},"proxy":{"donate_level":9}}',
            b'{"p2pool":{"stratum_password":[]}}',
            b'{"p2pool":{"stratum_tls":{}}}',
            b'{"proxy":{"donate_level":[]}}',
            b'{"proxy":{"donate_level":9223372036854775808}}',
            b'{"proxy":{"donate_level":"999999999999999999999999999999"}}',
            b'{"proxy":{"donate_level":1.5}}',
            b'{"proxy":{"donate_level":1e1}}',
            b'{"p2pool":{"stratum_password":"bad\\nvalue"}}',
            b'{"p2pool":{"stratum_password":"a\\u0000b"}}',
            b'{"proxy":{},"proxy":{"donate_level":1}}',
            b'{"proxy":false}',
        ]
        for raw in cases:
            with self.subTest(raw=raw):
                helper = self.helper(raw)
                self.assertEqual(self.result(helper), (125, b"", b""))
                self.compare(raw)
        raw = cases[0]
        for previous, expected_calls in [
            ("", b"env_get:PROXY_STRATUM_PASSWORD\ngenerate\n"),
            ("saved-password", b"env_get:PROXY_STRATUM_PASSWORD\n"),
            ("bad saved password", b"env_get:PROXY_STRATUM_PASSWORD\n"),
        ]:
            with self.subTest(previous=previous):
                completed, calls = self.compare(
                    raw, extra={"PROXY_SETTINGS_PREVIOUS_PASSWORD": previous}
                )
                self.assertEqual(calls, expected_calls)
                self.assertEqual(completed.returncode, 1 if " " in previous else 0)
        self.compare(raw, extra={"PROXY_SETTINGS_RANDOM_RC": "9"})

    def test_helper_failure_and_malformed_frames_do_not_poison_state(self):
        raw = self.encoded(
            {
                "p2pool": {"stratum_password": "valid", "stratum_tls": True},
                "proxy": {"donate_level": 7},
            }
        )
        baseline, calls = self.invoke("bash", raw)
        frames = [
            (b"", 125),
            (b"3\0poison\0false\099\0\0", 125),
            (b"3\0poison\0false\099\0\0trailing", 0),
            (b"3\0poison\0false\099\0\0extra\0", 0),
            (b"1\0poison\0\0\0\0", 0),
            (b"2\0poison\0false\099\0\0", 0),
            (b"3\0poison\0false", 0),
        ]
        for index, (frame, code) in enumerate(frames):
            with self.subTest(index=index):
                binary = self.directory / f"helper-{index}"
                binary.write_text(
                    "#!/usr/bin/env python3\nimport sys\nsys.stdout.buffer.write("
                    + repr(frame)
                    + ")\nsys.exit("
                    + str(code)
                    + ")\n"
                )
                binary.chmod(0o755)
                selected, selected_calls = self.invoke("go", raw, binary=binary)
                self.assertEqual(self.result(selected), self.result(baseline))
                self.assertEqual(selected_calls, calls)

    def test_missing_hook_and_file_refusals(self):
        self.compare(b"{}", extra={"PROXY_SETTINGS_WITHOUT_GO_HOOK": "1"})
        for path in [self.directory / "missing", self.directory, Path("-")]:
            with self.subTest(path=path):
                self.assertEqual(self.result(self.helper(None, path)), (125, b"", b""))


if __name__ == "__main__":
    unittest.main(verbosity=2)
