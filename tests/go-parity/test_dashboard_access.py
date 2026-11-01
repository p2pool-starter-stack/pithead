import json
import os
import shutil
import subprocess
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
ADAPTER = ROOT / "tests/go-parity/dashboard_access_reference.sh"
GO_BINARY = ROOT / "go/bin/pithead"
BASH = shutil.which("bash")
if BASH is None:
    raise RuntimeError("bash is required")

SEEDS = ("seed-host", "seed-port", "seed-secure", "seed-expose", "seed-timezone")


class DashboardAccessParityTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        completed = subprocess.run(  # noqa: S603
            [
                BASH,
                "-c",
                f'source "{ROOT}/lib/pithead/19a-config-defaults.sh"; config_defaults_json',
            ],
            capture_output=True,
            check=True,
            timeout=15,
        )
        cls.defaults_table = completed.stdout.rstrip(b"\n")

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
            DASHBOARD_ACCESS_PARITY_IMPL=implementation,
            DASHBOARD_ACCESS_CALL_LOG=str(self.calls),
            PITHEAD_GO_BINARY=str(binary or GO_BINARY),
            JQ_MARKER=str(self.marker),
        )
        if forbid_jq:
            env["PATH"] = str(self.tools) + os.pathsep + env.get("PATH", os.defpath)
        env.update(extra or {})
        return env

    def invoke(self, implementation, raw, *, binary=None, forbid_jq=False, extra=None):
        self.config.write_bytes(raw)
        self.calls.write_bytes(b"")
        self.marker.unlink(missing_ok=True)
        completed = subprocess.run(  # noqa: S603
            [BASH, str(ADAPTER), str(ROOT), str(self.config)],
            env=self.environment(implementation, binary, forbid_jq, extra),
            capture_output=True,
            check=False,
            timeout=15,
        )
        return completed, self.calls.read_bytes()

    def helper(self, raw, platform="diy", producer_status=b"0"):
        payload = b"\0".join((platform.encode(), self.defaults_table, raw, producer_status)) + b"\0"
        env = {key: value for key, value in os.environ.items() if not key.startswith("PITHEAD_")}
        env.pop("BASH_ENV", None)
        env["PITHEAD_GO_HELPER"] = "config-dashboard-access"
        return subprocess.run(  # noqa: S603
            [str(GO_BINARY)], env=env, input=payload, capture_output=True, check=False, timeout=15
        )

    def encoded(self, document):
        return json.dumps(document, ensure_ascii=False, separators=(",", ":")).encode()

    def result(self, completed):
        return completed.returncode, completed.stdout, completed.stderr

    def state(self, completed):
        values = completed.stdout.split(b"\0")
        self.assertEqual(len(values), 7)
        self.assertEqual((values[0], values[-1]), (b"", b""))
        return tuple(value.decode() for value in values[1:-1])

    def compare(self, raw, *, native=False, extra=None, binary=None):
        baseline, baseline_calls = self.invoke("bash", raw, extra=extra)
        selected, selected_calls = self.invoke(
            "go", raw, binary=binary, forbid_jq=native, extra=extra
        )
        self.assertEqual(self.result(selected), self.result(baseline))
        self.assertEqual(selected_calls, baseline_calls)
        if native:
            self.assertFalse(self.marker.exists())
        return selected, selected_calls

    def test_supported_values_and_host_timezone_order_match_without_jq(self):
        cases = [
            ({}, {}, ("", "", "true", "false", "Europe/Test")),
            (
                {
                    "dashboard": {
                        "host": "panel.example",
                        "port": 8443,
                        "secure": False,
                        "expose_public_ip": True,
                        "timezone": "America/Chicago",
                    }
                },
                {},
                ("panel.example", "8443", "false", "true", "America/Chicago"),
            ),
            (
                {"dashboard": {"host": False, "port": False, "secure": "yes", "timezone": False}},
                {"DASHBOARD_ACCESS_TIMEZONE": "Etc/UTC"},
                ("false", "", "yes", "false", "Etc/UTC"),
            ),
            (
                {"dashboard": {"host": "auto", "port": "auto", "timezone": "DYNAMIC_HOST"}},
                {"DASHBOARD_ACCESS_TIMEZONE": "Asia/Tokyo", "PITHEAD_APPLIANCE": "1"},
                ("", "", "true", "false", "Asia/Tokyo"),
            ),
        ]
        for sentinel in ("", "auto", "DYNAMIC_DATA", "DYNAMIC_HOST", "DYNAMIC_ID"):
            cases.append(
                (
                    {"dashboard": {"host": sentinel, "port": sentinel, "timezone": sentinel}},
                    {},
                    ("", "", "true", "false", "Europe/Test"),
                )
            )
        for host in ("a" * 253, "box_name", "2001:db8::5"):
            cases.append(
                ({"dashboard": {"host": host}}, {}, (host, "", "true", "false", "Europe/Test"))
            )
        for port in (1, 65535):
            cases.append(
                ({"dashboard": {"port": port}}, {}, ("", str(port), "true", "false", "Europe/Test"))
            )
        cases.extend(
            [
                (
                    {"dashboard": {"secure": "OFF", "expose_public_ip": "yes"}},
                    {},
                    ("", "", "OFF", "yes", "Europe/Test"),
                ),
                (
                    {"dashboard": {"secure": 2, "expose_public_ip": 3}},
                    {},
                    ("", "", "2", "3", "Europe/Test"),
                ),
            ]
        )
        for document, extra, expected in cases:
            with self.subTest(document=document):
                completed, calls = self.compare(self.encoded(document), native=True, extra=extra)
                self.assertEqual(completed.returncode, 0)
                self.assertEqual(self.state(completed), expected)
                self.assertEqual(
                    calls,
                    f"detect:{expected[0]}:{expected[1]}:{expected[2]}:{expected[3]}:seed-timezone\n".encode(),
                )

    def test_validation_errors_preserve_partial_state_and_skip_discovery(self):
        cases = [
            (
                {"dashboard": {"host": "bad host", "port": "bad"}},
                ("bad host", *SEEDS[1:]),
                b"dashboard.host",
            ),
            (
                {"dashboard": {"host": "panel.example", "port": "0655", "secure": False}},
                ("panel.example", "0655", *SEEDS[2:]),
                b"dashboard.port",
            ),
            (
                {"dashboard": {"host": "a" * 254}},
                ("a" * 254, *SEEDS[1:]),
                b"dashboard.host",
            ),
            (
                {"dashboard": {"host": "[2001:db8::5]"}},
                ("[2001:db8::5]", *SEEDS[1:]),
                b"dashboard.host",
            ),
        ]
        for port in (0, -1, 65536, "+1", "01"):
            cases.append(
                (
                    {"dashboard": {"host": "panel.example", "port": port}},
                    ("panel.example", str(port), *SEEDS[2:]),
                    b"dashboard.port",
                )
            )
        for document, expected, message in cases:
            with self.subTest(message=message):
                completed, calls = self.compare(self.encoded(document), native=True)
                self.assertEqual(completed.returncode, 1)
                self.assertEqual(self.state(completed), expected)
                self.assertIn(message, completed.stderr)
                self.assertEqual(calls, b"")

    def test_runtime_defaults_table_and_platform_select_missing_host(self):
        table = json.loads(self.defaults_table)
        table["values"]["dashboard"]["host"] = "diy.default"
        table["appliance"]["dashboard"]["host"] = "appliance.default"
        for entry in table["LEGACY_ABSENT"]:
            if entry["path"] == "dashboard.host":
                entry["value"] = "legacy.appliance"
        path = self.directory / "defaults.json"
        path.write_text(json.dumps(table, separators=(",", ":")))
        for appliance, expected in [("0", "diy.default"), ("1", "legacy.appliance")]:
            with self.subTest(appliance=appliance):
                completed, _ = self.compare(
                    b"{}",
                    native=True,
                    extra={
                        "DASHBOARD_ACCESS_DEFAULTS_FILE": str(path),
                        "PITHEAD_APPLIANCE": appliance,
                    },
                )
                self.assertEqual(completed.returncode, 0)
                self.assertEqual(self.state(completed)[0], expected)

    def test_detector_status_and_output_keep_reference_behavior(self):
        for timezone, expected in [("Europe/Berlin", "Europe/Berlin"), ("auto", "detected")]:
            with self.subTest(timezone=timezone):
                completed, calls = self.compare(
                    self.encoded({"dashboard": {"timezone": timezone}}),
                    native=True,
                    extra={
                        "DASHBOARD_ACCESS_TIMEZONE": "detected",
                        "DASHBOARD_ACCESS_TIMEZONE_RC": "9",
                        "DASHBOARD_ACCESS_ERR_TRAP": "1",
                    },
                )
                self.assertEqual(completed.returncode, 0)
                self.assertEqual(self.state(completed)[-1], expected)
                self.assertEqual(calls.count(b"detect:"), 1)
                self.assertEqual(calls.count(b"err:9\n"), 1)

    def test_unsupported_documents_fall_back_byte_for_byte(self):
        cases = [
            b'{"dashboard":{"host":[]}}',
            b'{"dashboard":{"port":1.5}}',
            b'{"dashboard":{"secure":{}}}',
            b'{"dashboard":{"expose_public_ip":[]}}',
            b'{"dashboard":{"timezone":"line\\u0001break"}}',
            b'{"dashboard":{"host":"one","host":"two"}}',
            b'{"dashboard":{"port":+1}}',
            b'{"dashboard":false}',
            b"[]",
            b"{",
        ]
        for raw in cases:
            with self.subTest(raw=raw):
                helper = self.helper(raw)
                self.assertEqual(self.result(helper), (125, b"", b""))
                self.compare(raw)

    def make_helper(self, name, output, status):
        path = self.directory / name
        path.write_text(
            "#!/usr/bin/env python3\nimport os\nimport sys\n"
            'if os.environ.get("PITHEAD_GO_HELPER") != "config-dashboard-access":\n'
            '    os.execv(os.environ["DASHBOARD_ACCESS_REAL_GO"], '
            '[os.environ["DASHBOARD_ACCESS_REAL_GO"], *sys.argv[1:]])\n'
            'with open(os.environ["DASHBOARD_ACCESS_HELPER_LOG"], "a") as log:\n'
            "    log.write(f\"{os.environ.get('PITHEAD_GO_HELPER', '')}:{len(sys.argv) - 1}\\n\")\n"
            "sys.stdin.buffer.read()\n"
            f"sys.stdout.buffer.write({output!r})\nsys.exit({status})\n"
        )
        path.chmod(0o755)
        return path

    def test_refused_malformed_and_missing_hook_fall_back_without_poison(self):
        frame = b"5\0poison\09999\0false\0true\0Poison/Zone\0false\0\0"
        helpers = [
            self.make_helper("refused", frame, 125),
            self.make_helper("extra", frame + b"extra\0", 0),
            self.make_helper("short", b"5\0poison\0", 0),
        ]
        raw = self.encoded({"dashboard": {"host": "panel.example", "port": 8080}})
        baseline, baseline_calls = self.invoke("bash", raw)
        missing, missing_calls = self.invoke(
            "go", raw, extra={"DASHBOARD_ACCESS_WITHOUT_GO_HOOK": "1"}
        )
        self.assertEqual(self.result(missing), self.result(baseline))
        self.assertEqual(missing_calls, baseline_calls)
        log = self.directory / "helper.log"
        for helper in helpers:
            with self.subTest(helper=helper.name):
                selected, calls = self.invoke(
                    "go",
                    raw,
                    binary=helper,
                    extra={
                        "DASHBOARD_ACCESS_HELPER_LOG": str(log),
                        "DASHBOARD_ACCESS_REAL_GO": str(GO_BINARY),
                    },
                )
                self.assertEqual(self.result(selected), self.result(baseline))
                self.assertEqual(calls, baseline_calls)
                self.assertNotIn(b"poison", selected.stdout)
        self.assertEqual(log.read_text().splitlines(), ["config-dashboard-access:0"] * len(helpers))

    def test_private_helper_frames_and_producer_refusal(self):
        cases = [
            ({}, "5", "true", ""),
            ({"dashboard": {"host": "bad host"}}, "1", "false", "dashboard.host"),
            ({"dashboard": {"port": 0}}, "2", "false", "dashboard.port"),
            ({"dashboard": {"timezone": "UTC"}}, "5", "false", ""),
        ]
        for document, assigned, needs, reason in cases:
            with self.subTest(document=document):
                completed = self.helper(self.encoded(document))
                self.assertEqual((completed.returncode, completed.stderr), (0, b""))
                fields = completed.stdout.split(b"\0")
                self.assertEqual(len(fields), 9)
                self.assertEqual(fields[0], assigned.encode())
                self.assertEqual(fields[6], needs.encode())
                self.assertEqual(fields[-1], b"")
                if reason:
                    self.assertIn(reason.encode(), fields[-2])
                else:
                    self.assertEqual(fields[-2], b"")
        self.assertEqual(self.result(self.helper(b"{}", producer_status=b"9")), (125, b"", b""))


if __name__ == "__main__":
    unittest.main(verbosity=2)
