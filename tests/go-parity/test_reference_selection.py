import os
import subprocess
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
GO_BINARY = ROOT / "go/bin/pithead"


class ReferenceSelectionTest(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(dir=ROOT / ".go-cache/tmp")
        self.directory = Path(self.temporary.name)
        self.marker = self.directory / "calls"
        self.document = self.directory / "config.json"
        self.document.write_text("{}\n")
        self.sentinel = self.directory / "native-sentinel"
        self.sentinel.write_text('#!/bin/sh\nprintf native >>"$CALLS"\nexit 99\n')
        self.sentinel.chmod(0o700)
        self.reference = self.directory / "reference"
        self.reference.write_text(
            'source "$PRELUDE"\n'
            'source "$PARSER"\n'
            'python3() { printf python >>"$CALLS"; command python3 "$@"; }\n'
            'config_document_error "$DOCUMENT"\n'
            'printf "selector=%s\\n" "${PITHEAD_IMPL-unset}"\n'
        )

    def tearDown(self):
        self.temporary.cleanup()

    def environment(self, mode):
        env = {
            key: value
            for key, value in os.environ.items()
            if not key.startswith(("PITHEAD_", "_PITHEAD_", "_pithead_")) and key != "BASH_ENV"
        }
        env.update(
            PRELUDE=str(ROOT / "lib/pithead/00-prelude.sh"),
            PARSER=str(ROOT / "lib/pithead/22a-config-document.sh"),
            DOCUMENT=str(self.document),
            CALLS=str(self.marker),
            NO_COLOR="1",
            PITHEAD_GO_BINARY=str(self.sentinel),
            PITHEAD_GO_CONFIG_DOCUMENT_BINARY=str(self.sentinel),
        )
        if mode is not None:
            env["PITHEAD_IMPL"] = mode
        return env

    def assert_reference(self, mode, command, overrides=None):
        env = self.environment(mode)
        env.update(overrides or {})
        result = subprocess.run(  # noqa: S603
            command, cwd=self.directory, env=env, capture_output=True, timeout=30, check=False
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout, f"selector={mode or 'unset'}\n".encode())
        self.assertEqual(self.marker.read_text(), "python")
        self.marker.unlink()

    def test_sourced_parser_ignores_public_native_helper_overrides(self):
        for mode in (None, "bash", "python"):
            with self.subTest(mode=mode):
                self.assert_reference(mode, ["bash", str(self.reference)])

    def test_direct_go_fallback_strips_inherited_hybrid_state(self):
        for mode in (None, "bash", "python"):
            with self.subTest(mode=mode):
                self.assert_reference(
                    mode,
                    [str(GO_BINARY), "unknown"],
                    {
                        "PITHEAD_GO_REFERENCE": str(self.reference),
                        "_PITHEAD_GO_HYBRID": "1",
                        "_pithead_go_hybrid_binary": str(self.sentinel),
                    },
                )

    def test_public_entrypoint_reference_modes_ignore_native_binary(self):
        for mode in (None, "bash", "python"):
            with self.subTest(mode=mode):
                result = subprocess.run(  # noqa: S603
                    [str(ROOT / "pithead"), "--help"],
                    cwd=self.directory,
                    env=self.environment(mode),
                    capture_output=True,
                    timeout=30,
                    check=False,
                )
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertIn(b"Usage:", result.stdout)
                self.assertFalse(self.marker.exists())

    def test_go_hybrid_keeps_native_helpers_with_reference_selector(self):
        env = self.environment("go")
        env["PITHEAD_GO_REFERENCE"] = str(self.reference)
        result = subprocess.run(  # noqa: S603
            [str(GO_BINARY), "unknown"],
            cwd=self.directory,
            env=env,
            capture_output=True,
            timeout=30,
            check=False,
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout, b"selector=bash\n")
        self.assertFalse(self.marker.exists())


if __name__ == "__main__":
    unittest.main()
