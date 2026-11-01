import json
import os
import shutil
import subprocess
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
ADAPTER = ROOT / "tests/go-parity/stratum_reference.sh"
GO_BINARY = ROOT / "go/bin/pithead"
BASH = shutil.which("bash")
if BASH is None:
    raise RuntimeError("bash is required")


class StratumParityTests(unittest.TestCase):
    def setUp(self):
        self.scratch = tempfile.TemporaryDirectory()
        self.addCleanup(self.scratch.cleanup)
        self.directory = Path(self.scratch.name)
        self.config = self.directory / "config.json"
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
            STRATUM_PARITY_IMPL=implementation,
            PITHEAD_GO_BINARY=str(binary or GO_BINARY),
            JQ_MARKER=str(self.marker),
        )
        if forbid_jq:
            env["PATH"] = str(self.tools) + os.pathsep + env.get("PATH", os.defpath)
        env.update(extra or {})
        return env

    def invoke(
        self,
        implementation,
        raw,
        *,
        repeat=1,
        binary=None,
        forbid_jq=False,
        missing=False,
        extra=None,
    ):
        if missing:
            self.config.unlink(missing_ok=True)
        else:
            self.config.write_bytes(raw)
        self.marker.unlink(missing_ok=True)
        return subprocess.run(  # noqa: S603
            [BASH, str(ADAPTER), str(ROOT), str(self.config), str(repeat)],
            env=self.environment(implementation, binary, forbid_jq, extra),
            capture_output=True,
            check=False,
            timeout=15,
        )

    def helper(self, raw, path=None):
        target = path or self.config
        if raw is not None:
            target.write_bytes(raw)
        env = {key: value for key, value in os.environ.items() if not key.startswith("PITHEAD_")}
        env.pop("BASH_ENV", None)
        env["PITHEAD_GO_HELPER"] = "config-stratum"
        return subprocess.run(  # noqa: S603
            [str(GO_BINARY), str(target)],
            env=env,
            capture_output=True,
            check=False,
            timeout=15,
        )

    def encoded(self, document):
        return json.dumps(document, ensure_ascii=False, separators=(",", ":")).encode()

    def result(self, completed):
        return completed.returncode, completed.stdout, completed.stderr

    def assert_state(self, completed, bind, port):
        self.assertEqual(completed.stdout.split(b"\0"), [b"", bind.encode(), port.encode(), b""])

    def test_supported_inputs_match_reference_without_jq(self):
        cases = [
            ({}, "0.0.0.0", "3333"),
            (None, "0.0.0.0", "3333"),
            ({"p2pool": {}}, "0.0.0.0", "3333"),
            ({"p2pool": None}, "0.0.0.0", "3333"),
            ({"p2pool": {"stratum_bind": None, "stratum_port": None}}, "0.0.0.0", "3333"),
            ({"p2pool": {"stratum_bind": False, "stratum_port": False}}, "0.0.0.0", "3333"),
            (
                {"p2pool": {"stratum_bind": "001.002.003.004", "stratum_port": "03333"}},
                "001.002.003.004",
                "03333",
            ),
            (
                {"p2pool": {"stratum_bind": "255.255.255.255", "stratum_port": 1}},
                "255.255.255.255",
                "1",
            ),
            (
                {"p2pool": {"stratum_bind": "127.0.0.1", "stratum_port": 65535}},
                "127.0.0.1",
                "65535",
            ),
        ]
        for index, (document, bind, port) in enumerate(cases):
            raw = self.encoded(document)
            with self.subTest(index=index):
                baseline = self.invoke("bash", raw)
                selected = self.invoke("go", raw, forbid_jq=True)
                self.assertEqual(self.result(selected), self.result(baseline))
                self.assertEqual(selected.returncode, 0)
                self.assert_state(selected, bind, port)
                self.assertFalse(self.marker.exists())

    def test_supported_errors_match_reference_without_jq(self):
        cases = [
            (
                {"p2pool": {"stratum_bind": "256.0.0.1"}},
                "256.0.0.1",
                "previous-port",
                "stratum_bind",
            ),
            ({"p2pool": {"stratum_bind": "1.2.3"}}, "1.2.3", "previous-port", "stratum_bind"),
            (
                {"p2pool": {"stratum_bind": "café.local"}},
                "café.local",
                "previous-port",
                "stratum_bind",
            ),
            ({"p2pool": {"stratum_port": 0}}, "0.0.0.0", "0", "stratum_port"),
            ({"p2pool": {"stratum_port": 65536}}, "0.0.0.0", "65536", "stratum_port"),
            ({"p2pool": {"stratum_port": -1}}, "0.0.0.0", "-1", "stratum_port"),
            ({"p2pool": {"stratum_port": True}}, "0.0.0.0", "true", "stratum_port"),
            ({"p2pool": {"stratum_port": "123456"}}, "0.0.0.0", "123456", "stratum_port"),
            (
                {"p2pool": {"stratum_bind": "bad", "stratum_port": 0}},
                "bad",
                "previous-port",
                "stratum_bind",
            ),
        ]
        for index, (document, bind, port, reason) in enumerate(cases):
            raw = self.encoded(document)
            with self.subTest(index=index):
                baseline = self.invoke("bash", raw)
                selected = self.invoke("go", raw, forbid_jq=True)
                self.assertEqual(self.result(selected), self.result(baseline))
                self.assertEqual(selected.returncode, 1)
                self.assertIn(reason.encode(), selected.stderr)
                self.assert_state(selected, bind, port)
                self.assertFalse(self.marker.exists())

    def test_repeat_parse_keeps_native_state_stable(self):
        raw = self.encoded({"p2pool": {"stratum_bind": "10.20.30.40", "stratum_port": 4444}})
        baseline = self.invoke("bash", raw, repeat=2)
        selected = self.invoke("go", raw, repeat=2, forbid_jq=True)
        self.assertEqual(self.result(selected), self.result(baseline))
        self.assert_state(selected, "10.20.30.40", "4444")
        self.assertFalse(self.marker.exists())

    def test_unsupported_documents_fall_back_byte_for_byte(self):
        cases = [
            b'{"p2pool":{"stratum_port":3333.0}}',
            b'{"p2pool":{"stratum_port":1e3}}',
            b'{"p2pool":{"stratum_port":1.5}}',
            b'{"p2pool":{"stratum_bind":["1.2.3.4"]}}',
            b'{"p2pool":{"stratum_port":{"value":3333}}}',
            b'{"p2pool":{"stratum_bind":"line\\u0001break"}}',
            b'{"p2pool":false}',
            b"[]",
            b"1",
            b'{"p2pool":{"stratum_bind":"1.2.3.4"},"p2pool":{"stratum_bind":"5.6.7.8"}}',
            b'{"p2pool":{"stratum_port":3333,"stratum_port":4444}}',
            b"{",
        ]
        for raw in cases:
            with self.subTest(raw=raw):
                baseline = self.invoke("bash", raw)
                selected = self.invoke("go", raw)
                self.assertEqual(self.result(selected), self.result(baseline))
                helper = self.helper(raw)
                self.assertEqual(self.result(helper), (125, b"", b""))
        baseline = self.invoke("bash", b"", missing=True)
        selected = self.invoke("go", b"", missing=True)
        self.assertEqual(self.result(selected), self.result(baseline))
        missing_helper = self.helper(None, self.config)
        self.assertEqual(self.result(missing_helper), (125, b"", b""))

    def make_helper(self, name, output, status):
        path = self.directory / name
        path.write_text(
            "#!/usr/bin/env bash\n"
            "set -Eeuo pipefail\n"
            'printf "%s:%s:%s\\n" "${PITHEAD_GO_HELPER:-}" "$#" "${1:-}" '
            '>>"$STRATUM_HELPER_LOG"\n'
            f"printf '{output}'\n"
            f"exit {status}\n"
        )
        path.chmod(0o755)
        return path

    def test_refused_and_malformed_helpers_fall_back_without_poisoning_state(self):
        log = self.directory / "helper.log"
        helpers = [
            self.make_helper("refused", r"ok\0poison-bind\0poison-port\0poison\0", 125),
            self.make_helper("extra", r"ok\0poison-bind\0poison-port\0\0extra\0", 0),
            self.make_helper("partial", r"bind-error\0poison-bind\0\0poison\0extra\0", 0),
        ]
        cases = [
            self.encoded({"p2pool": {"stratum_bind": "10.0.0.5", "stratum_port": 5555}}),
            self.encoded({"p2pool": {"stratum_bind": "bad", "stratum_port": 5555}}),
        ]
        for helper in helpers:
            for raw in cases:
                with self.subTest(helper=helper.name, raw=raw):
                    baseline = self.invoke("bash", raw)
                    selected = self.invoke(
                        "go",
                        raw,
                        binary=helper,
                        extra={"STRATUM_HELPER_LOG": str(log)},
                    )
                    self.assertEqual(self.result(selected), self.result(baseline))
                    self.assertNotIn(b"poison", selected.stdout)
        calls = log.read_text().splitlines()
        self.assertEqual(len(calls), len(helpers) * len(cases))
        self.assertTrue(all(line.startswith("config-stratum:1:") for line in calls))

    def test_private_helper_protocol(self):
        cases = [
            ({}, "ok", "0.0.0.0", "3333"),
            ({"p2pool": {"stratum_bind": "bad"}}, "bind-error", "bad", ""),
            ({"p2pool": {"stratum_port": 0}}, "port-error", "0.0.0.0", "0"),
        ]
        for document, stage, bind, port in cases:
            with self.subTest(stage=stage):
                result = self.helper(self.encoded(document))
                self.assertEqual((result.returncode, result.stderr), (0, b""))
                fields = result.stdout.split(b"\0")
                self.assertEqual(len(fields), 5)
                self.assertEqual(fields[:3], [stage.encode(), bind.encode(), port.encode()])
                self.assertEqual(fields[-1], b"")
                if stage == "ok":
                    self.assertEqual(fields[3], b"")
                else:
                    self.assertIn(
                        f"p2pool.stratum_{'bind' if stage == 'bind-error' else 'port'}".encode(),
                        fields[3],
                    )


if __name__ == "__main__":
    unittest.main()
