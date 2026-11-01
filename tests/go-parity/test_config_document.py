import os
import shutil
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
GO_BINARY = ROOT / "go/bin/pithead"
BASH = shutil.which("bash")
if BASH is None:
    raise RuntimeError("bash is required")


class ConfigDocumentGateTests(unittest.TestCase):
    def setUp(self):
        self.scratch = tempfile.TemporaryDirectory()
        self.addCleanup(self.scratch.cleanup)
        self.directory = Path(self.scratch.name)
        self.path = self.directory / "config.json"
        self.marker = self.directory / "python-called"
        self.tools = self.directory / "bin"
        self.tools.mkdir()
        python = self.tools / "python3"
        python.write_text('#!/bin/sh\nprintf called >"$PYTHON_MARKER"\nexit 91\n')
        python.chmod(0o755)

    def environment(self, implementation, forbid_python=False):
        env = {key: value for key, value in os.environ.items() if not key.startswith("PITHEAD_")}
        env.update(PITHEAD_IMPL=implementation, PITHEAD_GO_BINARY=str(GO_BINARY))
        if forbid_python:
            env["PATH"] = str(self.tools) + os.pathsep + env.get("PATH", os.defpath)
            env["PYTHON_MARKER"] = str(self.marker)
        return env

    def gate(self, implementation, raw, mode="config", forbid_python=False):
        if isinstance(raw, bytes):
            self.path.write_bytes(raw)
        else:
            self.path.write_text(raw)
        return subprocess.run(  # noqa: S603
            [
                BASH,
                "-c",
                'source "$1"; config_document_error "$2" "$3"',
                "test",
                str(ROOT / "lib/pithead/22a-config-document.sh"),
                str(self.path),
                mode,
            ],
            env=self.environment(implementation, forbid_python),
            capture_output=True,
            check=False,
            timeout=15,
        )

    def test_reference_and_selected_gate_match(self):
        for raw, mode in [
            ("{}", "config"),
            ('{"a":1,"a":2}', "config"),
            ('{"a":"YOUR_hidden"}', "config"),
            ('{"actor":"YOUR_actor","config":{}}', "request"),
            ('{"config":{"token":"PASTE_hidden"}}', "request"),
            ('{"a":1,"a":2,}', "config"),
            ('{"a":NaN}', "config"),
            ('{"a":Infinity}', "config"),
            ('{"\\ud800":"YOUR_hidden"}', "config"),
            (b'{"a":"\xff"}', "config"),
            ('{"a":' + "9" * 4097 + "}", "config"),
            ('{"a":' + "9" * 4301 + "}", "config"),
            ('{"a":-' + "9" * 4301 + "}", "config"),
            ("[" * 1200 + "0" + "]" * 1200, "config"),
        ]:
            with self.subTest(mode=mode):
                baseline = self.gate("bash", raw, mode)
                selected = self.gate("go", raw, mode)
                self.assertEqual(
                    (selected.returncode, selected.stdout, selected.stderr),
                    (baseline.returncode, baseline.stdout, baseline.stderr),
                )

    def test_native_cases_do_not_start_python(self):
        for raw, mode, code in [
            ("{}", "config", 0),
            ('{"a":1,"a":2}', "config", 1),
            ('{"a":"YOUR_hidden"}', "config", 1),
            ('{"actor":"YOUR_actor","config":{}}', "request", 0),
            ('{"bad\\nkey":"YOUR_hidden"}', "config", 1),
            ("{", "config", 1),
        ]:
            with self.subTest(mode=mode):
                selected = self.gate("go", raw, mode, forbid_python=True)
                self.assertEqual(selected.returncode, code)
                self.assertEqual(selected.stderr, b"")
                self.assertFalse(self.marker.exists())

    def test_fallback_cli_keeps_native_gate(self):
        reference = self.directory / "reference"
        reference.write_text('source "$SOURCE"\nconfig_document_error "$CANDIDATE"\n')
        self.path.write_text('{"password":"YOUR_hidden"}')
        env = self.environment("go", forbid_python=True)
        env.update(
            PITHEAD_GO_REFERENCE=str(reference),
            SOURCE=str(ROOT / "lib/pithead/22a-config-document.sh"),
            CANDIDATE=str(self.path),
        )
        result = subprocess.run(  # noqa: S603
            [str(GO_BINARY), "unported"], env=env, capture_output=True, check=False, timeout=15
        )
        self.assertEqual(result.returncode, 1)
        self.assertEqual(result.stdout, b"placeholder value at password\n")
        self.assertEqual(result.stderr, b"")
        self.assertFalse(self.marker.exists())

    def test_unsupported_helper_is_silent(self):
        self.path.write_text('{"a":NaN}')
        env = self.environment("go")
        env["PITHEAD_GO_HELPER"] = "config-document"
        result = subprocess.run(  # noqa: S603
            [str(GO_BINARY), str(self.path), "config"],
            env=env,
            capture_output=True,
            check=False,
            timeout=15,
        )
        self.assertEqual((result.returncode, result.stdout, result.stderr), (125, b"", b""))

    def test_missing_binary_uses_reference(self):
        self.path.write_text("{}")
        env = self.environment("go")
        env["PITHEAD_GO_BINARY"] = str(self.directory / "absent")
        result = subprocess.run(  # noqa: S603
            [
                BASH,
                "-c",
                'source "$1"; config_document_error "$2"',
                "test",
                str(ROOT / "lib/pithead/22a-config-document.sh"),
                str(self.path),
            ],
            env=env,
            capture_output=True,
            check=False,
            timeout=15,
        )
        self.assertEqual((result.returncode, result.stdout, result.stderr), (0, b"", b""))


if __name__ == "__main__":
    if not GO_BINARY.is_file():
        sys.exit("run make go-build first")
    unittest.main()
