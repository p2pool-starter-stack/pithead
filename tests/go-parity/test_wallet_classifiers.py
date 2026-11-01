import os
import re
import shutil
import subprocess
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
ADAPTER = ROOT / "tests/go-parity/wallet_classifiers_reference.sh"
GO_BINARY = ROOT / "go/bin/pithead"
BASH = shutil.which("bash")
PYTHON = shutil.which("python3")
if BASH is None or PYTHON is None:
    raise RuntimeError("bash and python3 are required")
FIXTURES = dict(
    re.findall(
        r'^((?:VALID_PRIMARY|VALID_SUBADDR|VALID_INTEGRATED|VALID_TARI\w*))="([^"]*)"$',
        (ROOT / "tests/stack/lib.sh").read_text(),
        re.MULTILINE,
    )
)


class WalletClassifiersParityTests(unittest.TestCase):
    def setUp(self):
        cache = ROOT / ".go-cache/tmp"
        cache.mkdir(parents=True, exist_ok=True)
        self.scratch = tempfile.TemporaryDirectory(dir=cache)
        self.addCleanup(self.scratch.cleanup)
        self.directory = Path(self.scratch.name)
        self.values = self.directory / "values"
        self.calls = self.directory / "calls"
        self.empty_path = self.directory / "empty-path"
        self.empty_path.mkdir()
        self.capture = self.directory / "helper-input"
        self.arguments = self.directory / "helper-arguments"

    def environment(self, implementation, extra=None):
        env = {k: v for k, v in os.environ.items() if not k.startswith("PITHEAD_")}
        env.pop("BASH_ENV", None)
        env.update(
            WALLET_CLASSIFIERS_IMPL=implementation,
            WALLET_CLASSIFIERS_CALLS=str(self.calls),
            WALLET_CLASSIFIERS_PYTHON=PYTHON,
            WALLET_CLASSIFIERS_EMPTY_PATH=str(self.empty_path),
            PITHEAD_GO_BINARY=str(GO_BINARY),
            LC_ALL="C",
        )
        env.update(extra or {})
        return env

    def invoke(self, implementation, operation, values, extra=None):
        self.values.write_bytes(
            b"\0".join(v.encode() if isinstance(v, str) else v for v in values) + b"\0"
        )
        self.calls.write_bytes(b"")
        result = subprocess.run(  # noqa: S603
            [BASH, str(ADAPTER), str(ROOT), operation, str(self.values)],
            env=self.environment(implementation, extra),
            capture_output=True,
            check=False,
            timeout=15,
        )
        return result, self.calls.read_bytes().splitlines()

    def compare(self, operation, values, *, extra=None, selected_extra=None, native=True):
        baseline, baseline_calls = self.invoke("bash", operation, values, extra)
        selected, selected_calls = self.invoke(
            "go", operation, values, {**(extra or {}), **(selected_extra or {})}
        )
        self.assertEqual(
            (selected.returncode, selected.stdout, selected.stderr),
            (baseline.returncode, baseline.stdout, baseline.stderr),
            (operation, values),
        )
        if native:
            self.assertEqual(selected_calls, [])
        else:
            self.assertEqual(selected_calls, baseline_calls)
        return selected, baseline_calls

    def helper(self, body):
        helper = self.directory / "helper"
        helper.write_text(
            "#!/usr/bin/env bash\nset -eu\n"
            'test "${PITHEAD_GO_HELPER:-}" = config-address || exit 125\n' + body
        )
        helper.chmod(0o755)
        return helper

    def test_monero_verdicts_use_native_classification(self):
        primary = FIXTURES["VALID_PRIMARY"]
        cases = [
            (primary, "primary"),
            (FIXTURES["VALID_SUBADDR"], "subaddress"),
            (FIXTURES["VALID_INTEGRATED"], "integrated"),
            ("4" + "A" * 94, "checksum"),
            (primary[:50] + "0" + primary[51:], "invalid"),
            ("4" + "1" * 10 + "z" * 11 + "1" * 73, "invalid"),
            ("4" + "A" * 93, "invalid"),
            ("", "invalid"),
            ("  " + primary, "invalid"),
        ]
        for value, verdict in cases:
            with self.subTest(verdict=verdict, value=value[:8]):
                selected, _ = self.compare("monero", [value])
                self.assertEqual(
                    (selected.returncode, selected.stdout), (0, (verdict + "\n").encode())
                )

    def test_tari_base58_and_emoji_verdicts_use_native_classification(self):
        tari = FIXTURES["VALID_TARI"]
        cases = [
            (tari, "ok"),
            (FIXTURES["VALID_TARI_EMOJI"], "ok"),
            (FIXTURES["VALID_TARI_SINGLE"], "ok"),
            (tari[:90] + "B", "checksum"),
            ("f" + tari[1:-2] + "Cb", "network"),
            ("T", "invalid"),
            ("", "invalid"),
            (FIXTURES["VALID_TARI_EMOJI"] + "\ufe0f", "invalid"),
            (tari + "\n", "invalid"),
        ]
        for value, verdict in cases:
            with self.subTest(verdict=verdict, value=value[:8]):
                selected, calls = self.compare("tari", [value])
                self.assertEqual(calls, [b"legacy"])
                self.assertEqual(
                    (selected.returncode, selected.stdout), (0, (verdict + "\n").encode())
                )

    def test_config_gate_preserves_error_text_order_and_off_mode(self):
        primary, tari = FIXTURES["VALID_PRIMARY"], FIXTURES["VALID_TARI"]
        cases = [
            ([primary, tari, "local"], b"accepted", 2),
            ([FIXTURES["VALID_SUBADDR"], "T", "local"], b"SUBADDRESS", 1),
            ([FIXTURES["VALID_INTEGRATED"], "T", "local"], b"INTEGRATED", 1),
            (["4" + "A" * 94, "T", "local"], b"fails its checksum", 1),
            (["4short", tari, "local"], b"not a valid Monero primary", 0),
            ([primary, tari[:90] + "B", "local"], b"tari.wallet_address fails", 2),
            ([primary, "f" + tari[1:-2] + "Cb", "local"], b"different Tari network", 2),
            ([primary, "T", "local"], b"not a valid Tari address", 2),
            ([primary, "T", "off"], b"accepted", 2),
        ]
        for values, expected, legacy_count in cases:
            with self.subTest(expected=expected):
                selected, calls = self.compare("gate", values)
                self.assertIn(expected, selected.stdout + selected.stderr)
                self.assertEqual(len(calls), legacy_count)
                self.assertEqual(selected.returncode, 0 if expected == b"accepted" else 1)

    def test_missing_broken_or_noisy_python_preserves_reference_fallback(self):
        for mode in ("missing", "broken", "noisy", "trailing-noise"):
            for chain, value in (("monero", "4" + "A" * 94), ("tari", FIXTURES["VALID_TARI"])):
                with self.subTest(mode=mode, chain=chain):
                    selected, _ = self.compare(
                        chain, [value], extra={"WALLET_CLASSIFIERS_PYTHON_MODE": mode}, native=False
                    )
                    self.assertEqual(selected.returncode, 0)

    def test_key_only_and_partial_source_paths_keep_reference(self):
        for chain, name in (("monero", "VALID_PRIMARY"), ("tari", "VALID_TARI_EMOJI")):
            with self.subTest(chain=chain):
                value = FIXTURES[name]
                result, calls = self.compare(
                    chain, [value], extra={chain.upper() + "_ADDRESS_KEY_ONLY": "1"}, native=False
                )
                self.assertRegex(result.stdout.decode(), r"^[0-9a-f]+\n$")
                self.assertEqual(calls, [b"legacy"])
                self.compare(
                    chain, [value], extra={"WALLET_CLASSIFIERS_WITHOUT_HOOK": "1"}, native=False
                )
                self.compare(chain, [value], extra={chain.upper() + "_ADDRESS_KEY_ONLY": "2"})

    def test_nonascii_monero_and_invalid_utf8_keep_reference(self):
        for locale in ("C", "C.UTF-8"):
            for chain, value in (
                ("monero", ("4" + "🐢" * 94).encode()),
                ("monero", b"4\xff" + b"A" * 93),
                ("tari", b"\xff"),
            ):
                with self.subTest(locale=locale, chain=chain):
                    self.compare(chain, [value], extra={"LC_ALL": locale}, native=False)

    def test_oversized_tari_preserves_python_argument_fallback(self):
        argument_limit = os.sysconf("SC_ARG_MAX") + 1
        for size in (4097, argument_limit):
            with self.subTest(size=size):
                result, calls = self.compare("tari", [b"A" * size], native=False)
                self.assertEqual(result.returncode, 0)
                self.assertEqual(calls, [b"legacy"])
                if size == argument_limit:
                    self.assertEqual(result.stdout, b"unchecked\n")

    def test_missing_binary_and_bad_helper_responses_keep_reference(self):
        value = FIXTURES["VALID_PRIMARY"]
        self.compare(
            "monero",
            [value],
            selected_extra={"PITHEAD_GO_BINARY": str(self.directory / "missing")},
            native=False,
        )
        responses = [
            "exit 91\n",
            "printf 'primary\\0'; exit 91\n",
            "printf 'primary'\n",
            "printf 'primary\\0extra\\0'\n",
            "printf 'primary\\0trailing'\n",
            "printf 'ok\\0'\n",
        ]
        for body in responses:
            with self.subTest(body=body):
                binary = self.helper(body)
                self.compare(
                    "monero",
                    [value],
                    selected_extra={"PITHEAD_GO_BINARY": str(binary)},
                    native=False,
                )

    def test_internal_marker_and_stdin_protocol_reach_go(self):
        value = FIXTURES["VALID_TARI_EMOJI"]
        binary = self.helper(
            'printf "%s\\n" "$#" >"$WALLET_CLASSIFIERS_ARGUMENTS"\n'
            '/bin/cat >"$WALLET_CLASSIFIERS_CAPTURE"\n'
            'exec "$WALLET_CLASSIFIERS_REAL_GO" <"$WALLET_CLASSIFIERS_CAPTURE"\n'
        )
        result, calls = self.invoke(
            "bash",
            "tari",
            [value],
            {
                "PITHEAD_GO_CONFIG_DOCUMENT_BINARY": str(binary),
                "WALLET_CLASSIFIERS_ARGUMENTS": str(self.arguments),
                "WALLET_CLASSIFIERS_CAPTURE": str(self.capture),
                "WALLET_CLASSIFIERS_REAL_GO": str(GO_BINARY),
            },
        )
        self.assertEqual(
            (result.returncode, result.stdout, result.stderr, calls), (0, b"ok\n", b"", [])
        )
        self.assertEqual(self.arguments.read_text(), "0\n")
        self.assertEqual(self.capture.read_bytes(), b"tari\0" + value.encode() + b"\x000\x00")


if __name__ == "__main__":
    if not GO_BINARY.is_file():
        raise SystemExit("run make go-build first")
    unittest.main()
