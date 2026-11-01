import os
import random
import shutil
import subprocess
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
ADAPTER = ROOT / "tests/go-parity/payout_keys_reference.sh"
GO_BINARY = ROOT / "go/bin/pithead"
BASH = shutil.which("bash")
if BASH is None:
    raise RuntimeError("bash is required")

L = 2**252 + 27742317777372353535851937790883648493
VIEW1 = "01" + "00" * 31
VIEW2 = "02" + "00" * 31
MONERO1 = "5866666666666666666666666666666666666666666666666666666666666666"
TARI1 = "e2f2ae0a6abc4e71a884a961c500515f58e30b6aa582dd8db6a65945e08d2d76"
SPEND = "ab" * 32


class PayoutKeyParityTests(unittest.TestCase):
    def setUp(self):
        cache = ROOT / ".go-cache"
        cache.mkdir(exist_ok=True)
        self.scratch = tempfile.TemporaryDirectory(dir=cache)
        self.addCleanup(self.scratch.cleanup)
        self.directory = Path(self.scratch.name)

    def work(self, name):
        path = self.directory / name
        path.mkdir()
        return path

    def environment(self, implementation, *, binary=None, extra=None, path=None):
        env = {key: value for key, value in os.environ.items() if not key.startswith("PITHEAD_")}
        env.pop("BASH_ENV", None)
        env.update(
            PAYOUT_KEYS_PARITY_IMPL=implementation,
            PITHEAD_GO_BINARY=str(binary or GO_BINARY),
            NO_COLOR="1",
            LC_ALL="C",
            LANG="C",
        )
        if path is not None:
            env["PATH"] = str(path)
        env.update(extra or {})
        return env

    def invoke(
        self, implementation, name, operation, fields, *, binary=None, extra=None, path=None
    ):
        return subprocess.run(  # noqa: S603
            [BASH, str(ADAPTER), str(ROOT), str(self.work(name)), operation],
            input=b"\0".join(fields) + b"\0",
            env=self.environment(implementation, binary=binary, extra=extra, path=path),
            capture_output=True,
            check=False,
            timeout=20,
        )

    def compare(self, name, operation, fields, *, binary=None, extra=None, path=None):
        expected = self.invoke("bash", name + "-bash", operation, fields, extra=extra, path=path)
        actual = self.invoke(
            "go", name + "-go", operation, fields, binary=binary, extra=extra, path=path
        )
        self.assertEqual(self.result(actual), self.result(expected))
        return actual

    def result(self, completed):
        return completed.returncode, completed.stdout, completed.stderr

    def scalar(self, value):
        return value.to_bytes(32, "little").hex().encode()

    def executable(self, name, body):
        path = self.directory / name
        path.write_text("#!/usr/bin/env python3\n" + body)
        path.chmod(0o755)
        return path

    def helper(self, fields, *, binary=None):
        env = self.environment("go", binary=binary)
        env["PITHEAD_GO_HELPER"] = "config-payout-keys"
        return subprocess.run(  # noqa: S603
            [str(binary or GO_BINARY)],
            input=b"\0".join(fields) + b"\0",
            env=env,
            capture_output=True,
            check=False,
            timeout=15,
        )

    def test_public_vectors_small_random_and_order_boundary_match(self):
        cases = [
            ("one", self.scalar(1)),
            ("two", self.scalar(2)),
            ("l-minus-one", self.scalar(L - 1)),
        ]
        generator = random.Random(3811)  # noqa: S311
        cases.extend(
            (f"random-{index}", self.scalar(generator.randrange(3, L))) for index in range(6)
        )
        for chain in (b"monero", b"tari"):
            for name, private in cases:
                with self.subTest(chain=chain, name=name):
                    result = self.compare(f"{chain.decode()}-{name}", "derive", [chain, private])
                    self.assertEqual(result.returncode, 0)
                    self.assertRegex(result.stdout, rb"^[0-9a-f]{64}\n$")
        self.assertEqual(
            self.compare("vector-monero", "derive", [b"monero", VIEW1.encode()]).stdout,
            (MONERO1 + "\n").encode(),
        )
        self.assertEqual(
            self.compare("vector-tari", "derive", [b"tari", VIEW1.encode()]).stdout,
            (TARI1 + "\n").encode(),
        )

    def test_hex_syntax_invalid_scalars_and_chains_match(self):
        spaced = (" \t01\n" + "00\r\n" * 31).upper().encode()
        cases = [
            ("spaced", b"monero", spaced),
            ("zero", b"monero", self.scalar(0)),
            ("order", b"tari", self.scalar(L)),
            ("sign-bit", b"monero", self.scalar(1 << 255)),
            ("huge", b"tari", b"01" + b"00" * 32),
            ("odd", b"monero", b"1"),
            ("bad-hex", b"tari", b"gg" + b"00" * 31),
            ("non-ascii-key", b"monero", b"\xff" + b"00" * 31),
            ("unknown-chain", b"other", VIEW1.encode()),
            ("non-ascii-chain", b"\xff", VIEW1.encode()),
        ]
        for name, chain, private in cases:
            with self.subTest(name=name):
                self.compare(name, "derive", [chain, private])

    def validation_fields(self, **changes):
        values = {
            "monero_view": VIEW1,
            "monero_wallet": "monero-wallet",
            "monero_keys": MONERO1,
            "monero_rc": "0",
            "tari_view": VIEW1,
            "tari_wallet": "tari-wallet",
            "tari_keys": "00" + TARI1 + SPEND,
            "tari_rc": "0",
            "spend": "",
        }
        values.update(changes)
        return [values[key].encode() for key in values]

    def test_validation_success_mismatch_address_and_spend_state_match(self):
        cases = [
            ("valid", {}, 0, SPEND),
            ("monero-mismatch", {"monero_keys": "00" * 32}, 1, ""),
            ("tari-mismatch", {"tari_keys": "00" + "00" * 32 + SPEND}, 1, ""),
            ("tari-single", {"monero_view": "", "tari_keys": "00" + TARI1}, 1, ""),
            ("tari-invalid", {"monero_view": "", "tari_keys": "bad"}, 1, ""),
            ("monero-address-failed", {"monero_rc": "7", "tari_view": ""}, 7, ""),
            ("tari-address-failed", {"monero_view": "", "tari_rc": "8"}, 8, ""),
            ("spend-match", {"spend": SPEND}, 0, SPEND),
            ("spend-mismatch", {"spend": "cd" * 32}, 1, SPEND),
        ]
        for name, changes, status, state in cases:
            with self.subTest(name=name):
                result = self.compare(name, "validate", self.validation_fields(**changes))
                self.assertEqual(result.returncode, status)
                self.assertEqual(result.stdout, b"\0" + state.encode() + b"\0")

    def test_invalid_private_key_validation_errors_match(self):
        for chain in ("monero", "tari"):
            changes = {"monero_view": "", "tari_view": ""}
            changes[chain + "_view"] = "00" * 32
            with self.subTest(chain=chain):
                result = self.compare(
                    chain + "-invalid-private", "validate", self.validation_fields(**changes)
                )
                self.assertEqual(result.returncode, 1)
                self.assertIn(("Cannot validate " + chain + ".view_key").encode(), result.stderr)

    def test_native_selection_keeps_scalar_off_argv_environment_and_python(self):
        marker = self.directory / "selection"
        python_marker = self.directory / "python-called"
        fake_bin = self.directory / "selection-bin"
        fake_bin.mkdir()
        fake_python = fake_bin / "python3"
        fake_python.write_text('#!/bin/sh\nprintf called >"$PYTHON_MARKER"\nexit 97\n')
        fake_python.chmod(0o755)
        spy = self.directory / "spy-helper"
        spy.write_text(
            f"#!{ROOT / 'dashboard/.venv/bin/python'}\n"
            "import os, sys\n"
            "data = sys.stdin.buffer.read()\n"
            "fields = data.split(b'\\0')\n"
            "assert sys.argv == [sys.argv[0]]\n"
            "assert not any('VIEW_SCALAR' in key for key in os.environ)\n"
            "assert fields == [b'monero', bytes.fromhex(os.environ['EXPECTED_SCALAR_HEX']), b'0', b'']\n"
            "open(os.environ['SELECTION_MARKER'], 'wb').write(b'config-payout-keys')\n"
            "sys.stdout.buffer.write(b'0\\0' + os.environ['EXPECTED_PUBLIC'].encode() + b'\\0')\n",
        )
        spy.chmod(0o755)
        env = {
            "EXPECTED_SCALAR_HEX": VIEW1.encode().hex(),
            "EXPECTED_PUBLIC": MONERO1,
            "SELECTION_MARKER": str(marker),
            "PYTHON_MARKER": str(python_marker),
        }
        result = self.invoke(
            "go",
            "native-selection",
            "derive",
            [b"monero", VIEW1.encode()],
            binary=spy,
            extra=env,
            path=fake_bin,
        )
        self.assertEqual(self.result(result), (0, (MONERO1 + "\n").encode(), b""))
        self.assertEqual(marker.read_bytes(), b"config-payout-keys")
        self.assertFalse(python_marker.exists())

    def test_missing_python_and_missing_hook_preserve_reference(self):
        empty_path = self.directory / "empty-path"
        empty_path.mkdir()
        missing = self.compare(
            "missing-python", "derive", [b"monero", VIEW1.encode()], path=empty_path
        )
        self.assertEqual(missing.returncode, 127)
        self.compare(
            "missing-hook",
            "derive",
            [b"monero", VIEW1.encode()],
            extra={"PAYOUT_KEYS_WITHOUT_GO_HOOK": "1"},
        )

    def test_helper_protocol_rejects_bad_frames_and_statuses(self):
        good = [b"monero", VIEW1.encode(), b"0"]
        result = self.helper(good)
        self.assertEqual(self.result(result), (0, b"0\0" + MONERO1.encode() + b"\0", b""))
        cases = [
            good[:-1],
            [*good, b"extra"],
            [b"monero", VIEW1.encode(), b"7"],
            [b"monero", VIEW1.encode(), b"-1"],
            [b"monero", VIEW1.encode(), b"00"],
        ]
        for fields in cases:
            with self.subTest(fields=fields):
                self.assertEqual(self.result(self.helper(fields)), (125, b"", b""))

    def test_bad_helper_results_fall_back_without_partial_output(self):
        bodies = {
            "refused": "import sys\nsys.stdin.buffer.read()\nsys.exit(125)\n",
            "failed": "import sys\nsys.stdin.buffer.read()\nsys.exit(7)\n",
            "partial": "import sys\nsys.stdin.buffer.read()\nsys.stdout.buffer.write(b'0\\0')\n",
            "trailing": "import sys\nsys.stdin.buffer.read()\nsys.stdout.buffer.write(b'0\\0' + b'0' * 64 + b'\\0extra')\n",
            "verdict": "import sys\nsys.stdin.buffer.read()\nsys.stdout.buffer.write(b'2\\0\\0')\n",
            "bad-key": "import sys\nsys.stdin.buffer.read()\nsys.stdout.buffer.write(b'0\\0BAD\\0')\n",
        }
        for name, body in bodies.items():
            with self.subTest(name=name):
                helper = self.executable("helper-" + name, body)
                result = self.compare(name, "derive", [b"monero", VIEW2.encode()], binary=helper)
                self.assertNotIn(b"BAD", result.stdout)


if __name__ == "__main__":
    unittest.main(verbosity=2)
