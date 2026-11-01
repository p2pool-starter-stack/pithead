import os
import shutil
import subprocess
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
ADAPTER = ROOT / "tests/go-parity/payout_ownership_reference.sh"
GO_BINARY = ROOT / "go/bin/pithead"
BASH = shutil.which("bash")
if BASH is None:
    raise RuntimeError("bash is required")

VIEW1 = "01" + "00" * 31
VIEW2 = "02" + "00" * 31
MONERO1 = "44yQXfkWZNmJ8QgRfFWTzmJ8QgRfFWTzmJ8QgRfFWTzmJ7suhUXwdrDJ8QgRfFWTzmJ8QgRfFWTzmJ8QgRfFWTzmCYrSgjJ"
MONERO_PUBLIC1 = "5866666666666666666666666666666666666666666666666666666666666666"
MONERO_PUBLIC2 = "c9a3f86aae465f0e56513864510f3997561fa2c9e85ea21dc2292309f3cd6022"
TARI1 = (
    "12M2aZjsSvTTcaFyzLxARkvwdxv8UHJeJBA6E1pEoP967ydCL8tv17vktNDHhqDgFg5LxtHrp9Wsd1cuhyW1p6fzimM"
)
TARI_PUBLIC1 = "e2f2ae0a6abc4e71a884a961c500515f58e30b6aa582dd8db6a65945e08d2d76"
TARI_PUBLIC2 = "6a493210f7499cd17fecb510ae0cea23a110e8d5b901f8acadd3095c73a3b919"
SPEND = TARI_PUBLIC1
DOCS = "https://docs.example"


class PayoutOwnershipParityTests(unittest.TestCase):
    def setUp(self):
        cache = ROOT / ".go-cache"
        cache.mkdir(exist_ok=True)
        self.scratch = tempfile.TemporaryDirectory(dir=cache)
        self.addCleanup(self.scratch.cleanup)
        self.directory = Path(self.scratch.name)

    def environment(self, implementation, *, binary=None, extra=None, path=None):
        env = {key: value for key, value in os.environ.items() if not key.startswith("PITHEAD_")}
        env.pop("BASH_ENV", None)
        env.update(
            PAYOUT_OWNERSHIP_PARITY_IMPL=implementation,
            PITHEAD_GO_BINARY=str(binary or GO_BINARY),
            NO_COLOR="1",
            LC_ALL="C",
            LANG="C",
        )
        if path is not None:
            env["PATH"] = str(path)
        env.update(extra or {})
        return env

    def fields(self, **changes):
        values = {
            "mode": "stub",
            "monero_view": VIEW1,
            "monero_wallet": "monero-wallet",
            "monero_keys": MONERO_PUBLIC1,
            "monero_address_rc": "0",
            "monero_derived": MONERO_PUBLIC1,
            "monero_derive_rc": "0",
            "tari_view": VIEW1,
            "tari_wallet": "tari-wallet",
            "tari_keys": "00" + TARI_PUBLIC1 + SPEND,
            "tari_address_rc": "0",
            "tari_derived": TARI_PUBLIC1,
            "tari_derive_rc": "0",
            "spend": "",
            "docs": DOCS,
        }
        values.update(changes)
        return [values[key].encode() for key in values]

    def invoke(self, implementation, name, fields, *, binary=None, extra=None, path=None):
        work = self.directory / name
        work.mkdir()
        completed = subprocess.run(  # noqa: S603
            [BASH, str(ADAPTER), str(ROOT), str(work)],
            input=b"\0".join(fields) + b"\0",
            env=self.environment(implementation, binary=binary, extra=extra, path=path),
            capture_output=True,
            check=False,
            timeout=20,
        )
        return completed, work

    def compare(self, name, fields, *, binary=None, extra=None, path=None):
        expected, expected_work = self.invoke(
            "bash", name + "-bash", fields, extra=extra, path=path
        )
        actual, actual_work = self.invoke(
            "go", name + "-go", fields, binary=binary, extra=extra, path=path
        )
        self.assertEqual(self.result(actual), self.result(expected))
        return actual, expected_work, actual_work

    @staticmethod
    def result(completed):
        return completed.returncode, completed.stdout, completed.stderr

    def executable(self, name, body):
        path = self.directory / name
        path.write_text(f"#!{ROOT / 'dashboard/.venv/bin/python'}\n" + body)
        path.chmod(0o755)
        return path

    def helper(self, fields, *, binary=None):
        env = self.environment("go", binary=binary)
        env["PITHEAD_GO_HELPER"] = "config-payout-ownership"
        return subprocess.run(  # noqa: S603
            [str(binary or GO_BINARY)],
            input=b"\0".join(fields) + b"\0",
            env=env,
            capture_output=True,
            check=False,
            timeout=15,
        )

    def test_real_public_addresses_match_and_derive_spend(self):
        fields = self.fields(
            mode="real",
            monero_wallet=MONERO1,
            tari_wallet=TARI1,
            monero_keys="",
            monero_derived="",
            tari_keys="",
            tari_derived="",
        )
        result, _, _ = self.compare("real-pairs", fields)
        self.assertEqual(result.returncode, 0)
        self.assertEqual(
            result.stdout, ("\0" + SPEND + "\0monero-address\ntari-address\0").encode()
        )

    def test_empty_keys_skip_chains_and_preserve_spend(self):
        result, _, _ = self.compare(
            "empty", self.fields(monero_view="", tari_view="", spend="existing")
        )
        self.assertEqual(self.result(result), (0, b"\0existing\0\0", b""))
        monero, _, _ = self.compare("monero-only", self.fields(tari_view="", spend="existing"))
        self.assertEqual(monero.stdout, b"\0existing\0monero-address\0")
        tari, _, _ = self.compare("tari-only", self.fields(monero_view=""))
        self.assertEqual(tari.stdout, ("\0" + SPEND + "\0tari-address\0").encode())

    def test_mismatch_invalid_scalar_and_chain_priority_match(self):
        cases = (
            (
                "monero-mismatch",
                {"monero_keys": MONERO_PUBLIC2},
                b"monero.view_key does not belong",
            ),
            (
                "tari-mismatch",
                {"monero_view": "", "tari_keys": "00" + TARI_PUBLIC2 + SPEND},
                b"tari.view_key does not belong",
            ),
            (
                "monero-invalid-scalar",
                {
                    "monero_view": "00" * 32,
                    "monero_derived": "",
                    "monero_derive_rc": "1",
                    "tari_view": "",
                },
                b"Cannot validate monero.view_key",
            ),
            (
                "tari-invalid-scalar",
                {
                    "monero_view": "",
                    "tari_view": "00" * 32,
                    "tari_derived": "",
                    "tari_derive_rc": "1",
                },
                b"Cannot validate tari.view_key",
            ),
            (
                "monero-first",
                {
                    "monero_keys": MONERO_PUBLIC2,
                    "tari_keys": "00" + TARI_PUBLIC2 + SPEND,
                },
                b"monero.view_key does not belong",
            ),
        )
        for name, changes, message in cases:
            with self.subTest(name=name):
                result, _, _ = self.compare(name, self.fields(**changes))
                self.assertEqual(result.returncode, 1)
                self.assertIn(message, result.stderr)

    def test_tari_decoded_key_lengths_and_spend_mismatch_state_match(self):
        cases = (
            ("single", "00" + TARI_PUBLIC1, "", b"dual-key address"),
            ("short", "bad", "", b"Cannot decode tari.wallet_address"),
            ("long", "00" + TARI_PUBLIC1 + SPEND + "00", "", b"Cannot decode tari.wallet_address"),
            (
                "spend-mismatch",
                "00" + TARI_PUBLIC1 + SPEND,
                "cd" * 32,
                b"tari.spend_public_key disagrees",
            ),
        )
        for name, keys, explicit, message in cases:
            with self.subTest(name=name):
                result, _, _ = self.compare(
                    "tari-" + name,
                    self.fields(monero_view="", tari_keys=keys, spend=explicit),
                )
                self.assertEqual(result.returncode, 1)
                self.assertIn(message, result.stderr)
                expected = SPEND if name == "spend-mismatch" else explicit
                self.assertTrue(result.stdout.startswith(("\0" + expected + "\0").encode()))
        unicode_result, _, _ = self.compare(
            "tari-unicode-single",
            self.fields(monero_view="", tari_keys="é" * 66),
            extra={"LC_ALL": "C.UTF-8", "LANG": "C.UTF-8"},
        )
        self.assertEqual(unicode_result.returncode, 1)
        self.assertIn(b"dual-key address", unicode_result.stderr)
        invalid = self.fields(monero_view="", tari_view=VIEW2)
        invalid[9] = b"\xff" * 66
        invalid_result, _, _ = self.compare("tari-invalid-utf8-single", invalid)
        self.assertEqual(invalid_result.returncode, 1)
        self.assertIn(b"dual-key address", invalid_result.stderr)
        self.assertNotIn(VIEW2.encode(), invalid_result.stdout + invalid_result.stderr)

    def test_address_callback_failures_and_error_order_match(self):
        monero, _, _ = self.compare(
            "monero-address-failure",
            self.fields(monero_address_rc="7", tari_view=""),
        )
        self.assertEqual(monero.returncode, 7)
        self.assertEqual(monero.stdout, b"\0\0monero-address\0")
        tari, _, _ = self.compare(
            "tari-address-failure",
            self.fields(monero_view="", tari_address_rc="8", spend="seed"),
        )
        self.assertEqual(tari.returncode, 8)
        self.assertEqual(tari.stdout, b"\0seed\0tari-address\0")
        mismatch, _, _ = self.compare(
            "callback-error-order",
            self.fields(monero_keys=MONERO_PUBLIC2),
        )
        self.assertEqual(mismatch.stdout, b"\0\0monero-address\nerror\0")

    def test_helper_missing_malformed_and_protocol_failures_fall_back(self):
        bodies = {
            "refused": "import sys\nsys.stdin.buffer.read()\nsys.exit(125)\n",
            "failed": "import sys\nsys.stdin.buffer.read()\nsys.stdout.buffer.write(b'poison')\nsys.exit(7)\n",
            "partial": "import sys\nsys.stdin.buffer.read()\nsys.stdout.buffer.write(b'1\\0')\n",
            "trailing": "import sys\nsys.stdin.buffer.read()\nsys.stdout.buffer.write(b'1\\0' + b'a' * 64 + b'\\0\\0extra')\n",
            "bad-flag": "import sys\nsys.stdin.buffer.read()\nsys.stdout.buffer.write(b'2\\0\\0\\0')\n",
        }
        for name, body in bodies.items():
            with self.subTest(name=name):
                helper = self.executable("helper-" + name, body)
                result, _, selected = self.compare(name, self.fields(tari_view=""), binary=helper)
                self.assertEqual(result.returncode, 0)
                self.assertNotIn(b"poison", result.stdout + result.stderr)
                self.assertEqual((selected / "derivations").read_text(), "monero-derive\n")
        missing = self.directory / "missing-helper"
        result, _, selected = self.compare(
            "missing-helper", self.fields(tari_view=""), binary=missing
        )
        self.assertEqual(result.returncode, 0)
        self.assertEqual((selected / "derivations").read_text(), "monero-derive\n")

    def test_python_missing_hook_missing_and_failed_producer_fall_back(self):
        empty_path = self.directory / "empty-path"
        empty_path.mkdir()
        self.compare("python-missing", self.fields(tari_view=""), path=empty_path)
        self.compare(
            "hook-missing",
            self.fields(tari_view=""),
            extra={"PAYOUT_OWNERSHIP_WITHOUT_GO_HOOK": "1"},
        )
        helper = self.executable("early-exit", "import sys\nsys.exit(0)\n")
        result, _, selected = self.compare(
            "producer-failure",
            self.fields(tari_view="", docs="x" * 262144),
            binary=helper,
        )
        self.assertEqual(result.returncode, 0)
        self.assertEqual((selected / "derivations").read_text(), "monero-derive\n")

    def test_native_selection_keeps_secrets_on_stdin(self):
        marker = self.directory / "native-frame"
        expected = self.directory / "expected-frame"
        python_marker = self.directory / "python-called"
        fake_bin = self.directory / "selection-bin"
        fake_bin.mkdir()
        fake_python = fake_bin / "python3"
        fake_python.write_text('#!/bin/sh\nprintf called >"$PYTHON_MARKER"\nexit 97\n')
        fake_python.chmod(0o755)
        spy = self.executable(
            "spy-helper",
            "import os, sys\n"
            "data = sys.stdin.buffer.read()\n"
            "fields = data.split(b'\\0')\n"
            "assert sys.argv == [sys.argv[0]]\n"
            "assert os.environ['PITHEAD_GO_HELPER'] == 'config-payout-ownership'\n"
            "assert not any('VIEW_KEY' in key for key in os.environ)\n"
            "assert data == open(os.environ['EXPECTED_FRAME'], 'rb').read()\n"
            "open(os.environ['SELECTION_MARKER'], 'wb').write(data)\n"
            "sys.stdout.buffer.write(b'0\\0\\0\\0')\n",
        )
        expected.write_bytes(
            b"monero\0"
            + MONERO_PUBLIC1.encode()
            + b"\0"
            + VIEW1.encode()
            + b"\0\0https://docs.example\0"
            + b"0\0"
        )
        result, work = self.invoke(
            "go",
            "native-selection",
            self.fields(tari_view=""),
            binary=spy,
            path=fake_bin,
            extra={
                "EXPECTED_FRAME": str(expected),
                "SELECTION_MARKER": str(marker),
                "PYTHON_MARKER": str(python_marker),
            },
        )
        self.assertEqual(result.returncode, 0)
        self.assertTrue(marker.exists())
        self.assertFalse(python_marker.exists())
        self.assertFalse((work / "derivations").exists())

    def test_helper_frames_and_verdicts(self):
        valid = [b"monero", MONERO_PUBLIC1.encode(), VIEW1.encode(), b"", DOCS.encode(), b"0"]
        self.assertEqual(self.result(self.helper(valid)), (0, b"0\0\0\0", b""))
        tari = [
            b"tari",
            ("00" + TARI_PUBLIC1 + SPEND).encode(),
            VIEW1.encode(),
            b"",
            DOCS.encode(),
            b"0",
        ]
        self.assertEqual(
            self.result(self.helper(tari)), (0, ("1\0" + SPEND + "\0\0").encode(), b"")
        )
        cases = (
            valid[:-1],
            [*valid, b"extra"],
            [b"other", *valid[1:]],
            [*valid[:-1], b"1"],
            [*valid[:-1], b"00"],
        )
        for fields in cases:
            with self.subTest(fields=fields):
                self.assertEqual(self.result(self.helper(fields)), (125, b"", b""))


if __name__ == "__main__":
    unittest.main(verbosity=2)
