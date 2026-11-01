import json
import os
import shutil
import subprocess
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
GO_BINARY = ROOT / "go/bin/pithead"
ADAPTER = ROOT / "tests/go-parity/config_validation_reference.sh"
BASH = shutil.which("bash")
if BASH is None:
    raise RuntimeError("bash is required")


class ConfigValidationParityTests(unittest.TestCase):
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

    def environment(self, implementation, forbid_jq=False):
        env = {key: value for key, value in os.environ.items() if not key.startswith("PITHEAD_")}
        env.update(
            VALIDATION_PARITY_IMPL=implementation,
            PITHEAD_GO_BINARY=str(GO_BINARY),
            JQ_MARKER=str(self.marker),
        )
        if forbid_jq:
            env["PATH"] = str(self.tools) + os.pathsep + env.get("PATH", os.defpath)
        return env

    def invoke(self, implementation, section, raw, forbid_jq=False):
        self.config.write_bytes(raw)
        self.marker.unlink(missing_ok=True)
        return subprocess.run(  # noqa: S603
            [BASH, str(ADAPTER), str(ROOT), section, str(self.config)],
            env=self.environment(implementation, forbid_jq),
            capture_output=True,
            check=False,
            timeout=15,
        )

    def invoke_helper(self, section, path):
        return subprocess.run(  # noqa: S603
            [str(GO_BINARY), section, str(path)],
            env={**self.environment("go"), "PITHEAD_GO_HELPER": "config-validation"},
            capture_output=True,
            check=False,
            timeout=15,
        )

    def assert_parity(self, section, document):
        raw = (
            document
            if isinstance(document, bytes)
            else json.dumps(document, ensure_ascii=False, separators=(",", ":")).encode()
        )
        baseline = self.invoke("bash", section, raw)
        selected = self.invoke("go", section, raw)
        self.assertEqual(
            (selected.returncode, selected.stdout, selected.stderr),
            (baseline.returncode, baseline.stdout, baseline.stderr),
            (section, raw),
        )

    def test_worker_corpus(self):
        cases = [
            {},
            {"workers": None},
            {"workers": False},
            {"workers": {}},
            {"workers": {"list": []}},
            {"workers": {"api_port": 1}},
            {"workers": {"api_port": 65535}},
        ]
        cases += [{"workers": {"api_port": value}} for value in (0, 65536, 1.5, "1", None, True)]
        cases += [{"workers": {"list": value}} for value in ({}, "rig", 1, True)]
        cases += [{"workers": {"list": [value]}} for value in (None, "rig", 1, [], True)]
        cases += [
            {"workers": {"list": [{"name": name}]}}
            for name in (None, "", "has space", "é", "x" * 129)
        ]
        cases += [
            {"workers": {"list": [{"name": "x"}]}},
            {"workers": {"list": [{"name": "x" * 128}]}},
            {"workers": {"list": [{"name": "rig", "unknown": 1}]}},
            {"workers": {"list": [{"name": "rig", "host": "node_1.example"}]}},
            {"workers": {"list": [{"name": "rig", "host": None}]}},
            {"workers": {"list": [{"name": "rig", "host": "host:18081"}]}},
            {"workers": {"list": [{"name": "rig", "host": "x" * 254}]}},
        ]
        for field in ("port", "control_port"):
            for value in (1, 65535, 1.0, 0, 65536, 1.5, "1", None, True):
                cases.append({"workers": {"list": [{"name": "rig", field: value}]}})
        for field in ("token", "api_token"):
            for value in ("x", "!" * 128, "", "has space", "é", "x" * 129, None, 1):
                worker = {"name": "rig", field: value}
                if field == "api_token":
                    worker["host"] = "node"
                cases.append({"workers": {"list": [worker]}})
        cases += [
            {"workers": {"list": [{"name": "rig", "api_token": "x"}]}},
        ]
        cases += [
            {"workers": {"list": [{"name": "rig", "watts": value}]}}
            for value in (0.1, 999999.9, 0, -1, 1000000, "1", None, True)
        ]
        cases += [
            {"workers": {"list": [{"name": "b"}, {"name": "b"}]}},
            {"workers": {"list": [{"name": "z"}, {"name": "z"}, {"name": "a"}, {"name": "a"}]}},
        ]
        for index, case in enumerate(cases):
            with self.subTest(index=index):
                self.assert_parity("workers", case)

    def test_energy_corpus(self):
        cases = [
            {},
            {"dashboard": {}},
            {"dashboard": {"energy": None}},
            {"dashboard": {"energy": False}},
        ]
        cases += [{"dashboard": {"energy": value}} for value in (True, [], "energy", 1)]
        cases += [
            {"dashboard": {"energy": {}}},
            {"dashboard": {"energy": {"extra": 1}}},
            {"dashboard": {"energy": {"z": 1, "a": 2}}},
            {"dashboard": {"energy": {"\x00": 1}}},
            {"dashboard": {"energy": {"\x01": 1}}},
            {"dashboard": {"energy": {"\x7f": 1}}},
            {"dashboard": {"energy": {"é": 1, "a": 2}}},
        ]
        for field in ("cost_per_kwh", "xmr_price", "tari_price"):
            for value in (0, 0.1, 1000000, -0.1, "1", None, True, []):
                cases.append({"dashboard": {"energy": {field: value}}})
        for value in ("USD", "!" * 128, "", "US D", "é", "x" * 129, None, 1):
            cases.append({"dashboard": {"energy": {"currency": value}}})
        for value in (True, False, None, 0, "true", []):
            cases.append({"dashboard": {"energy": {"price_feed": value}}})
        for index, case in enumerate(cases):
            with self.subTest(index=index):
                self.assert_parity("energy", case)

    def test_webhook_corpus(self):
        cases = [{}, {"notifications": {}}, {"notifications": {"webhooks": None}}]
        cases += [
            {"notifications": {"webhooks": value}}
            for value in ([], [""], ["https://example.invalid/hook"], True, False, {}, "url", 1)
        ]
        for value in (None, True, False, {}, [], 1, 1.5):
            cases.append({"notifications": {"webhooks": ["ok", value]}})
        for index, case in enumerate(cases):
            with self.subTest(index=index):
                self.assert_parity("webhooks", case)

    def test_control_character_corpus(self):
        cases = [
            {},
            {"value": "plain"},
            {"value": "é"},
            {"value": "~"},
            {"value": "\u00a0"},
            {"line\nkey": "plain"},
        ]
        cases += [{"value": chr(code)} for code in list(range(32)) + list(range(127, 160))]
        cases += [
            {"nested": [{"safe": "yes"}, {"value": f"a{chr(code)}b"}]}
            for code in (0, 9, 10, 13, 31, 127)
        ]
        for index, case in enumerate(cases):
            with self.subTest(index=index):
                self.assert_parity("controls", case)

    def test_supported_sections_bypass_jq(self):
        cases = [
            ("workers", {}),
            ("workers", {"workers": {"api_port": 0}}),
            ("workers", {"workers": {"list": [{"name": "rig"}, {"name": "rig"}]}}),
            ("energy", {}),
            ("energy", {"dashboard": {"energy": {"cost_per_kwh": -1}}}),
            ("webhooks", {}),
            ("webhooks", {"notifications": {"webhooks": [None]}}),
            ("controls", {}),
            ("controls", {"value": "line\nbreak"}),
        ]
        for section, document in cases:
            raw = json.dumps(document, separators=(",", ":")).encode()
            with self.subTest(section=section):
                baseline = self.invoke("bash", section, raw)
                selected = self.invoke("go", section, raw, forbid_jq=True)
                self.assertEqual(
                    (selected.returncode, selected.stdout, selected.stderr),
                    (baseline.returncode, baseline.stdout, baseline.stderr),
                )
                self.assertFalse(self.marker.exists())

    def test_missing_binary_falls_back_to_jq(self):
        raw = b'{"workers":{"api_port":0}}'
        baseline = self.invoke("bash", "workers", raw)
        self.config.write_bytes(raw)
        env = self.environment("go")
        env["PITHEAD_GO_BINARY"] = str(self.directory / "missing-pithead")
        selected = subprocess.run(  # noqa: S603
            [BASH, str(ADAPTER), str(ROOT), "workers", str(self.config)],
            env=env,
            capture_output=True,
            check=False,
            timeout=15,
        )
        self.assertEqual(
            (selected.returncode, selected.stdout, selected.stderr),
            (baseline.returncode, baseline.stdout, baseline.stderr),
        )

    def test_unsupported_inputs_fall_back_byte_for_byte(self):
        cases = [
            ("webhooks", b"{"),
            ("webhooks", b'{"notifications":{"webhooks":[]},"notifications":{}}'),
            ("webhooks", b"[]"),
            ("workers", b'{"workers":{"api_port":1.0}}'),
            ("workers", b'{"workers":{"api_port":1e3}}'),
            ("workers", b'{"workers":{"api_port":-0}}'),
            ("workers", b'{"workers":{"list":[{"name":"rig","port":1e9999}]}}'),
            ("workers", b'{"workers":{"list":[{"name":"rig","port":1.00000000000000000001}]}}'),
            ("workers", b'{"workers":{"list":[{"name":"rig","watts":999999.9999999999999999}]}}'),
            ("workers", b'{"workers":{"list":[{"name":"rig","watts":1e-999}]}}'),
            ("energy", b'{"dashboard":1}'),
            ("energy", b'{"dashboard":{"energy":{"cost_per_kwh":-1e-999}}}'),
            ("energy", b'{"dashboard":{"energy":{"cost_per_kwh":-0.' + b"0" * 400 + b"1}}}"),
            ("workers", b'{"workers":{"list":[{"name":"rig","watts":0.' + b"0" * 400 + b"1}]}}"),
        ]
        for section, raw in cases:
            with self.subTest(section=section, raw=raw):
                self.assert_parity(section, raw)

    def test_private_helper_rejects_unsupported_requests_silently(self):
        self.config.write_text("{}")
        missing = self.directory / "missing.json"
        for args in (("unknown", str(self.config)), ("workers", str(missing)), ("workers", "-")):
            with self.subTest(args=args):
                result = self.invoke_helper(*args)
                self.assertEqual((result.returncode, result.stdout, result.stderr), (125, b"", b""))

    def test_private_helper_status_protocol(self):
        cases = [
            ("workers", b"{}", 0),
            ("workers", b'{"workers":{"api_port":0}}', 1),
            ("workers", b'{"workers":{"list":[{"name":"rig"},{"name":"rig"}]}}', 2),
            ("energy", b'{"dashboard":{"energy":{"cost_per_kwh":-1}}}', 1),
            ("webhooks", b'{"notifications":{"webhooks":[null]}}', 1),
            ("controls", b'{"value":"line\\nbreak"}', 1),
        ]
        for section, raw, status in cases:
            with self.subTest(section=section, status=status):
                self.config.write_bytes(raw)
                result = self.invoke_helper(section, self.config)
                self.assertEqual(result.returncode, status)
                self.assertEqual(result.stderr, b"")
                if status == 0:
                    self.assertEqual(result.stdout, b"")
                else:
                    self.assertTrue(result.stdout.endswith(b"\n"))

    def test_private_helper_defers_unsupported_documents_silently(self):
        cases = [
            ("webhooks", b"{"),
            ("webhooks", b'{"notifications":{"webhooks":[]},"notifications":{}}'),
            ("webhooks", b"[]"),
            ("energy", b'{"dashboard":1}'),
            ("energy", b'{"dashboard":{"energy":{"\\u0000":1}}}'),
            ("workers", b'{"workers":{"api_port":1.0}}'),
            ("workers", b'{"workers":{"api_port":1e3}}'),
            ("workers", b'{"workers":{"api_port":-0}}'),
            ("workers", b'{"workers":{"list":[{"name":"rig","port":1e9999}]}}'),
            ("workers", b'{"workers":{"list":[{"name":"rig","port":1.00000000000000000001}]}}'),
            ("workers", b'{"workers":{"list":[{"name":"rig","watts":999999.9999999999999999}]}}'),
            ("workers", b'{"workers":{"list":[{"name":"rig","watts":1e-999}]}}'),
            ("energy", b'{"dashboard":{"energy":{"cost_per_kwh":-1e-999}}}'),
            ("energy", b'{"dashboard":{"energy":{"cost_per_kwh":-0.' + b"0" * 400 + b"1}}}"),
            ("workers", b'{"workers":{"list":[{"name":"rig","watts":0.' + b"0" * 400 + b"1}]}}"),
        ]
        for section, raw in cases:
            with self.subTest(section=section, raw=raw):
                self.config.write_bytes(raw)
                result = self.invoke_helper(section, self.config)
                self.assertEqual((result.returncode, result.stdout, result.stderr), (125, b"", b""))

    def test_cli_fallback_marker_keeps_native_validation(self):
        self.config.write_text('{"dashboard":{"energy":{"currency":""}}}')
        reference = self.directory / "reference.sh"
        reference.write_text(
            'source "$VALIDATION_ROOT/lib/pithead/00-prelude.sh"\n'
            'source "$VALIDATION_ROOT/lib/pithead/22a-config-document.sh"\n'
            'source "$VALIDATION_ROOT/lib/pithead/27-defaults-and-config-validation.sh"\n'
            "validate_energy_config\n"
        )
        baseline = self.invoke("bash", "energy", self.config.read_bytes())
        env = self.environment("go", forbid_jq=True)
        env.update(
            PITHEAD_IMPL="go",
            PITHEAD_GO_REFERENCE=str(reference),
            PITHEAD_CONFIG_FILE=str(self.config),
            VALIDATION_ROOT=str(ROOT),
        )
        selected = subprocess.run(  # noqa: S603
            [str(GO_BINARY), "unported"],
            env=env,
            capture_output=True,
            check=False,
            timeout=15,
        )
        self.assertEqual(
            (selected.returncode, selected.stdout, selected.stderr),
            (baseline.returncode, baseline.stdout, baseline.stderr),
        )
        self.assertFalse(self.marker.exists())


if __name__ == "__main__":
    unittest.main()
