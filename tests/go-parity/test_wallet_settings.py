import json
import os
import shutil
import subprocess
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
ADAPTER = ROOT / "tests/go-parity/wallet_settings_reference.sh"
GO_BINARY = ROOT / "go/bin/pithead"
BASH = shutil.which("bash")
if BASH is None:
    raise RuntimeError("bash is required")

MONERO = "4wallet"
TARI = "tari-wallet"
EMOJI = "🐢📟🌈🍓🚓🎸🍷🎣🐒🍯👾🍾🌊🎉"
SEEDS = ("seed-mode", "seed-monero-wallet", "seed-tari-wallet")


class WalletSettingsParityTests(unittest.TestCase):
    def setUp(self):
        cache = ROOT / ".go-cache"
        cache.mkdir(exist_ok=True)
        self.scratch = tempfile.TemporaryDirectory(dir=cache)
        self.addCleanup(self.scratch.cleanup)
        self.directory = Path(self.scratch.name)
        self.config = self.directory / "config.json"
        self.calls = self.directory / "calls"
        self.traps = self.directory / "traps"
        self.marker = self.directory / "forbidden-jq"
        self.forbidden = self.directory / "forbidden-bin"
        self.forbidden.mkdir()
        jq = self.forbidden / "jq"
        jq.write_text('#!/bin/sh\nprintf "jq\\n" >>"$WALLET_SETTINGS_FORBIDDEN_LOG"\nexit 91\n')
        jq.chmod(0o755)

    def environment(self, implementation, binary=None, native=False, extra=None):
        env = {key: value for key, value in os.environ.items() if not key.startswith("PITHEAD_")}
        env.pop("BASH_ENV", None)
        path = env.get("PATH", os.defpath)
        env.update(
            WALLET_SETTINGS_PARITY_IMPL=implementation,
            WALLET_SETTINGS_CALL_LOG=str(self.calls),
            WALLET_SETTINGS_TRAP_LOG=str(self.traps),
            WALLET_SETTINGS_FORBIDDEN_LOG=str(self.marker),
            PITHEAD_GO_BINARY=str(binary or GO_BINARY),
            PATH=str(self.forbidden) + os.pathsep + path if native else path,
        )
        env.update(extra or {})
        return env

    def invoke(self, implementation, raw, *, binary=None, native=False, extra=None):
        self.config.write_bytes(raw)
        self.calls.write_bytes(b"")
        self.traps.write_bytes(b"")
        self.marker.unlink(missing_ok=True)
        completed = subprocess.run(  # noqa: S603
            [BASH, str(ADAPTER), str(ROOT), str(self.config)],
            env=self.environment(implementation, binary, native, extra),
            capture_output=True,
            check=False,
            timeout=15,
        )
        return completed, self.calls.read_bytes(), self.traps.read_bytes()

    def compare(self, document, *, native=True, extra=None, binary=None):
        raw = document if isinstance(document, bytes) else self.encoded(document)
        baseline = self.invoke("bash", raw, extra=extra)
        selected = self.invoke("go", raw, binary=binary, native=native, extra=extra)
        self.assertEqual(self.result(selected[0]), self.result(baseline[0]))
        self.assertEqual(selected[1:], baseline[1:])
        if native:
            self.assertFalse(self.marker.exists())
        return selected

    def encoded(self, document):
        return json.dumps(document, ensure_ascii=False, separators=(",", ":")).encode()

    def result(self, completed):
        return completed.returncode, completed.stdout, completed.stderr

    def state(self, completed):
        values = completed.stdout.split(b"\0")
        self.assertEqual((len(values), values[0], values[-1]), (5, b"", b""))
        return tuple(value.decode() for value in values[1:-1])

    def helper(self, parts, binary=None):
        env = {key: value for key, value in os.environ.items() if not key.startswith("PITHEAD_")}
        env.pop("BASH_ENV", None)
        env["PITHEAD_GO_HELPER"] = "config-wallet-settings"
        return subprocess.run(  # noqa: S603
            [str(binary or GO_BINARY)],
            env=env,
            input=b"\0".join(parts) + b"\0",
            capture_output=True,
            check=False,
            timeout=15,
        )

    def test_supported_modes_wallets_and_classifier_order_match_without_jq(self):
        cases = [
            (
                {"tari": {"wallet_address": TARI}, "monero": {"wallet_address": MONERO}},
                ("local", MONERO, TARI),
            ),
            (
                {
                    "tari": {"mode": "local", "wallet_address": TARI},
                    "monero": {"wallet_address": MONERO},
                },
                ("local", MONERO, TARI),
            ),
            (
                {
                    "tari": {"mode": "remote", "wallet_address": TARI},
                    "monero": {"wallet_address": MONERO},
                },
                ("remote", MONERO, TARI),
            ),
            ({"tari": {"mode": "off"}, "monero": {"wallet_address": MONERO}}, ("off", MONERO, "")),
        ]
        for document, expected in cases:
            with self.subTest(mode=expected[0]):
                selected = self.compare(document)
                self.assertEqual((selected[0].returncode, self.state(selected[0])), (0, expected))
                self.assertEqual(selected[1].count(b"get:.tari.mode\n"), 1)
                self.assertEqual(selected[1].count(b"monero:"), 1)
                self.assertEqual(selected[1].count(b"tari:"), 1)

    def test_command_substitution_trims_trailing_linefeeds(self):
        cases = (
            ("local", "monero\n\n", "tari\n\n", ("local", "monero", "tari")),
            ("local", "\n", "tari\n", ("local", "", "tari")),
            ("local", "monero\n", "\n", ("local", "monero", "")),
            ("off", "monero\n", "\n", ("off", "monero", "")),
            ("local", "monero", "tari\nwallet\n", ("local", "monero", "tari\nwallet")),
        )
        for mode, monero, tari, expected in cases:
            with self.subTest(mode=mode, monero=monero, tari=tari):
                selected = self.compare(
                    {
                        "tari": {"mode": mode, "wallet_address": tari},
                        "monero": {"wallet_address": monero},
                    }
                )
                self.assertEqual(self.state(selected[0]), expected)

    def test_gate_errors_preserve_partial_assignment_and_callback_boundary(self):
        cases = [
            (
                {"tari": {"mode": "bad"}},
                ("bad", SEEDS[1], SEEDS[2]),
                b"tari.mode",
                0,
            ),
            (
                {"tari": {"mode": "local", "wallet_address": TARI}},
                ("local", "", TARI),
                b"Missing required",
                0,
            ),
            (
                {"tari": {"mode": "local"}, "monero": {"wallet_address": MONERO}},
                ("local", MONERO, ""),
                b"Missing required",
                0,
            ),
            (
                {
                    "tari": {"mode": "off", "wallet_address": "bad value"},
                    "monero": {"wallet_address": MONERO},
                },
                ("off", MONERO, "bad value"),
                b"contains whitespace",
                0,
            ),
        ]
        for document, expected, message, classifiers in cases:
            with self.subTest(message=message):
                selected = self.compare(document)
                self.assertEqual(selected[0].returncode, 1)
                self.assertEqual(self.state(selected[0]), expected)
                self.assertIn(message, selected[0].stderr)
                self.assertEqual(
                    selected[1].count(b"monero:") + selected[1].count(b"tari:"), classifiers
                )
                self.assertEqual(selected[1].count(b"get:.tari.mode\n"), 1)

    def test_original_classifier_verdicts_and_order_remain_authoritative(self):
        document = {
            "tari": {"mode": "local", "wallet_address": TARI},
            "monero": {"wallet_address": MONERO},
        }
        cases = [
            ({"WALLET_SETTINGS_MONERO_KIND": "subaddress"}, b"SUBADDRESS", [b"monero:"]),
            ({"WALLET_SETTINGS_MONERO_KIND": "integrated"}, b"INTEGRATED", [b"monero:"]),
            ({"WALLET_SETTINGS_MONERO_KIND": "checksum"}, b"fails its checksum", [b"monero:"]),
            ({"WALLET_SETTINGS_MONERO_KIND": "invalid"}, b"not a valid Monero", [b"monero:"]),
            (
                {"WALLET_SETTINGS_TARI_KIND": "checksum"},
                b"fails its checksum",
                [b"monero:", b"tari:"],
            ),
            (
                {"WALLET_SETTINGS_TARI_KIND": "network"},
                b"different Tari network",
                [b"monero:", b"tari:"],
            ),
            ({"WALLET_SETTINGS_TARI_KIND": "invalid"}, b"not a valid Tari", [b"monero:", b"tari:"]),
        ]
        for extra, message, order in cases:
            with self.subTest(extra=extra):
                selected = self.compare(document, extra=extra)
                self.assertEqual(selected[0].returncode, 1)
                self.assertIn(message, selected[0].stderr)
                actual = [
                    line.split(b":", 1)[0] + b":"
                    for line in selected[1].splitlines()
                    if line.startswith((b"monero:", b"tari:"))
                ]
                self.assertEqual(actual, order)
        off = self.compare(
            {"tari": {"mode": "off", "wallet_address": TARI}, "monero": {"wallet_address": MONERO}},
            extra={"WALLET_SETTINGS_TARI_KIND": "checksum"},
        )
        self.assertEqual(off[0].returncode, 0)
        self.assertEqual(off[1].count(b"tari:"), 1)

    def make_spy(self, name):
        path = self.directory / name
        path.write_text(
            '#!/usr/bin/env bash\nset -Eeuo pipefail\nif "$WALLET_SETTINGS_REAL_GO" "$@"; then rc=0; else rc=$?; fi\n'
            'printf "%s:%s:%s\\n" "${PITHEAD_GO_HELPER:-}" "$#" "$rc" >>"$WALLET_SETTINGS_HELPER_LOG"\nexit "$rc"\n'
        )
        path.chmod(0o755)
        return path

    def test_unicode_selection_matches_in_c_and_utf8_locales(self):
        spy = self.make_spy("spy")
        log = self.directory / "helper.log"
        cases = ((EMOJI, 0), ("tari\u00a0wallet", 125))
        for locale in ("C", "C.UTF-8"):
            for wallet, helper_rc in cases:
                log.write_text("")
                document = {
                    "tari": {"mode": "local", "wallet_address": wallet},
                    "monero": {"wallet_address": MONERO},
                }
                with self.subTest(locale=locale, helper_rc=helper_rc):
                    selected = self.compare(
                        document,
                        native=False,
                        binary=spy,
                        extra={
                            "LC_ALL": locale,
                            "WALLET_SETTINGS_REAL_GO": str(GO_BINARY),
                            "WALLET_SETTINGS_HELPER_LOG": str(log),
                        },
                    )
                    if helper_rc == 0:
                        self.assertEqual(selected[0].returncode, 0)
                    self.assertEqual(
                        [
                            line
                            for line in log.read_text().splitlines()
                            if line.startswith("config-wallet-settings:")
                        ],
                        [f"config-wallet-settings:0:{helper_rc}"],
                    )

    def test_unsupported_documents_fall_back_byte_for_byte(self):
        cases = [
            b'{"tari":{"mode":[]}}',
            b'{"monero":{"wallet_address":{}}}',
            b'{"tari":{"wallet_address":[]}}',
            b'{"tari":{"wallet_address":1.5}}',
            b'{"tari":{"wallet_address":"one","wallet_address":"two"}}',
            b'{"monero":{"wallet_address":"line\\u0001break"}}',
            b"[]",
            b"{",
        ]
        for raw in cases:
            with self.subTest(raw=raw):
                self.compare(raw, native=False)

    def make_helper(self, name):
        path = self.directory / name
        path.write_text(
            "#!/usr/bin/env python3\nimport os, sys\n"
            "if os.environ.get('PITHEAD_GO_HELPER') != 'config-wallet-settings':\n"
            " os.execve(os.environ['WALLET_SETTINGS_REAL_GO'], [os.environ['WALLET_SETTINGS_REAL_GO'], *sys.argv[1:]], os.environ)\n"
            "data=sys.stdin.buffer.read()\n"
            "open(os.environ['WALLET_SETTINGS_HELPER_LOG'],'a').write(f'{os.environ.get(\"PITHEAD_GO_HELPER\",\"\")}:{len(sys.argv)-1}:{len(data)}\\n')\n"
            "sys.stdout.buffer.write(bytes.fromhex(os.environ.get('FAKE_HEX','')))\n"
            "sys.exit(int(os.environ.get('FAKE_RC','125')))\n"
        )
        path.chmod(0o755)
        return path

    def test_refused_malformed_and_missing_hooks_fall_back_without_poison(self):
        raw = self.encoded(
            {
                "tari": {"mode": "local", "wallet_address": TARI},
                "monero": {"wallet_address": MONERO},
            }
        )
        baseline = self.invoke("bash", raw)
        missing = self.invoke("go", raw, extra={"WALLET_SETTINGS_WITHOUT_GO_HOOK": "1"})
        self.assertEqual(
            (self.result(missing[0]), missing[1:]), (self.result(baseline[0]), baseline[1:])
        )
        helper = self.make_helper("fake-helper")
        helper_log = self.directory / "helper.log"
        for payload, rc in [
            (b"", 125),
            (b"2\0poison\0", 0),
            (b"3\0x\0y\0\0", 0),
            (b"0\0x\0y\0\0", 0),
        ]:
            helper_log.write_text("")
            with self.subTest(payload=payload):
                selected = self.compare(
                    raw,
                    native=False,
                    binary=helper,
                    extra={
                        "WALLET_SETTINGS_HELPER_LOG": str(helper_log),
                        "WALLET_SETTINGS_REAL_GO": str(GO_BINARY),
                        "FAKE_HEX": payload.hex(),
                        "FAKE_RC": str(rc),
                    },
                )
                self.assertNotIn(b"poison", selected[0].stdout)
                self.assertEqual(
                    helper_log.read_text().split(":", 2)[:2], ["config-wallet-settings", "0"]
                )
                self.assertEqual(selected[1].count(b"get:.tari.mode\n"), 1)

    def test_private_helper_protocol_and_silent_refusals(self):
        raw = self.encoded({"tari": {"wallet_address": TARI}, "monero": {"wallet_address": MONERO}})
        valid = self.helper([raw, b"local", str(self.config).encode(), b"0"])
        self.assertEqual((valid.returncode, valid.stderr), (0, b""))
        self.assertEqual(
            valid.stdout.split(b"\0"), [b"2", MONERO.encode(), TARI.encode(), b"", b""]
        )
        bad = self.helper([raw, b"bad", str(self.config).encode(), b"0"])
        self.assertEqual((bad.returncode, bad.stderr), (0, b""))
        self.assertEqual(bad.stdout.split(b"\0")[:2], [b"0", b""])
        self.assertIn(b"tari.mode", bad.stdout)
        for parts in ([raw, b"local", str(self.config).encode(), b"9"], [raw, b"local", b"only"]):
            refused = self.helper(parts)
            self.assertEqual(self.result(refused), (125, b"", b""))


if __name__ == "__main__":
    unittest.main(verbosity=2)
