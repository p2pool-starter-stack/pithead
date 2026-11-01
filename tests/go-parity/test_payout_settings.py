import json
import os
import shutil
import subprocess
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
ADAPTER = ROOT / "tests/go-parity/payout_settings_reference.sh"
GO_BINARY = ROOT / "go/bin/pithead"
BASH = shutil.which("bash")
if BASH is None:
    raise RuntimeError("bash is required")

KEY = "01" + "00" * 31
FIELDS = 8
SEEDS = (
    "seed-monero-mode",
    "seed-monero-view-key",
    "seed-scan-height",
    "seed-monero-enabled",
    "seed-tari-view-key",
    "seed-tari-spend-key",
    "seed-birthday",
    "seed-tari-enabled",
)


class PayoutSettingsParityTests(unittest.TestCase):
    def setUp(self):
        cache = ROOT / ".go-cache"
        cache.mkdir(exist_ok=True)
        self.scratch = tempfile.TemporaryDirectory(dir=cache)
        self.addCleanup(self.scratch.cleanup)
        self.directory = Path(self.scratch.name)
        self.config = self.directory / "config.json"
        self.calls = self.directory / "calls"
        self.traps = self.directory / "traps"
        self.marker = self.directory / "forbidden-called"
        self.common = self.directory / "common-bin"
        self.forbidden = self.directory / "forbidden-bin"
        self.common.mkdir()
        self.forbidden.mkdir()
        date = '#!/bin/sh\nprintf "date:%s\\n" "$*" >>"$PAYOUT_SETTINGS_CALL_LOG"\nprintf "%s\\n" "${PAYOUT_SETTINGS_EPOCH:-1813795200}"\nexit "${PAYOUT_SETTINGS_DATE_RC:-0}"\n'
        for directory in (self.common, self.forbidden):
            path = directory / "date"
            path.write_text(date)
            path.chmod(0o755)
        for name in ("jq", "grep"):
            path = self.forbidden / name
            path.write_text(
                '#!/bin/sh\nprintf "%s\\n" "$0" >>"$PAYOUT_SETTINGS_FORBIDDEN_LOG"\nexit 91\n'
            )
            path.chmod(0o755)

    def environment(self, implementation, binary=None, native=False, extra=None):
        env = {key: value for key, value in os.environ.items() if not key.startswith("PITHEAD_")}
        env.pop("BASH_ENV", None)
        tools = self.forbidden if native else self.common
        env.update(
            PAYOUT_SETTINGS_PARITY_IMPL=implementation,
            PAYOUT_SETTINGS_CALL_LOG=str(self.calls),
            PAYOUT_SETTINGS_TRAP_LOG=str(self.traps),
            PAYOUT_SETTINGS_FORBIDDEN_LOG=str(self.marker),
            PITHEAD_GO_BINARY=str(binary or GO_BINARY),
            PATH=str(tools) + os.pathsep + env.get("PATH", os.defpath),
        )
        env.update(extra or {})
        return env

    def invoke(
        self, implementation, raw, tari_mode="local", *, binary=None, native=False, extra=None
    ):
        self.config.write_bytes(raw)
        self.calls.write_bytes(b"")
        self.traps.write_bytes(b"")
        self.marker.unlink(missing_ok=True)
        completed = subprocess.run(  # noqa: S603
            [BASH, str(ADAPTER), str(ROOT), str(self.config), tari_mode],
            env=self.environment(implementation, binary, native, extra),
            capture_output=True,
            check=False,
            timeout=15,
        )
        return completed, self.calls.read_bytes(), self.traps.read_bytes()

    def compare(self, document, tari_mode="local", *, native=True, extra=None, binary=None):
        raw = document if isinstance(document, bytes) else self.encoded(document)
        baseline = self.invoke("bash", raw, tari_mode, extra=extra)
        selected = self.invoke("go", raw, tari_mode, binary=binary, native=native, extra=extra)
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
        self.assertEqual(len(values), FIELDS + 2)
        self.assertEqual((values[0], values[-1]), (b"", b""))
        return tuple(value.decode() for value in values[1:-1])

    def helper(self, mode, parts, binary=None):
        env = {key: value for key, value in os.environ.items() if not key.startswith("PITHEAD_")}
        env.pop("BASH_ENV", None)
        env["PITHEAD_GO_HELPER"] = "config-payout-settings"
        return subprocess.run(  # noqa: S603
            [str(binary or GO_BINARY), mode],
            env=env,
            input=b"\0".join(parts) + b"\0",
            capture_output=True,
            check=False,
            timeout=15,
        )

    def test_supported_defaults_and_inert_values_match_without_jq_or_grep(self):
        cases = [
            ({}, "local", ("local", "", "auto", "false", "", "", "auto", "false")),
            (
                {
                    "monero": {"mode": "remote", "view_key": None, "payout_scan_height": "bad"},
                    "tari": {"view_key": False, "spend_public_key": 7, "payout_scan_birthday": -1},
                },
                "off",
                ("remote", "", "bad", "false", "", "7", "-1", "false"),
            ),
            (
                {
                    "monero": {"mode": "local", "view_key": KEY, "payout_scan_height": "00042"},
                    "tari": {"view_key": "", "payout_scan_birthday": "future"},
                },
                "local",
                ("local", KEY, "00042", "true", "", "", "future", "false"),
            ),
        ]
        for document, tari_mode, expected in cases:
            with self.subTest(document=document):
                selected = self.compare(document, tari_mode)
                self.assertEqual(selected[0].returncode, 0)
                self.assertEqual(self.state(selected[0]), expected)
                self.assertEqual(selected[1].count(b"validate:"), 1)
                self.assertEqual(selected[1].count(b"date:+%s\n"), 0)

    def test_supported_tari_birthdays_keep_date_and_validator_order(self):
        today = 2000
        epoch = str(1640995200 + today * 86400)
        for birthday in ("", "auto", 0, "00000", 1999, "02000"):
            document = {
                "tari": {
                    "view_key": KEY,
                    "spend_public_key": False,
                    "payout_scan_birthday": birthday,
                }
            }
            with self.subTest(birthday=birthday):
                selected = self.compare(document, extra={"PAYOUT_SETTINGS_EPOCH": epoch})
                self.assertEqual(selected[0].returncode, 0)
                expected = "" if birthday == "" else str(birthday)
                self.assertEqual(self.state(selected[0])[6:], (expected, "true"))
                self.assertTrue(selected[1].startswith(b"date:+%s\nvalidate:"))

    def test_supported_errors_preserve_partial_state_and_callback_boundary(self):
        today_epoch = str(1640995200 + 2000 * 86400)
        cases = [
            ({"monero": {"mode": "bad"}}, "local", ("bad", *SEEDS[1:]), b"monero.mode", False),
            ({"monero": {"mode": 1}}, "local", ("1", *SEEDS[1:]), b"monero.mode", False),
            (
                {"monero": {"mode": "remote", "view_key": KEY}},
                "local",
                ("remote", KEY, "auto", "false", *SEEDS[4:]),
                b"monero.view_key",
                False,
            ),
            (
                {"monero": {"view_key": "A" * 64}},
                "local",
                ("local", "A" * 64, "auto", "false", *SEEDS[4:]),
                b"monero.view_key",
                False,
            ),
            (
                {"monero": {"view_key": "a" * 65}},
                "local",
                ("local", "a" * 65, "auto", "false", *SEEDS[4:]),
                b"monero.view_key",
                False,
            ),
            (
                {"monero": {"view_key": KEY, "payout_scan_height": -1}},
                "local",
                ("local", KEY, "-1", "false", *SEEDS[4:]),
                b"payout_scan_height",
                False,
            ),
            (
                {"tari": {"view_key": KEY}},
                "remote",
                ("local", "", "auto", "false", KEY, "", "auto", "false"),
                b"tari.view_key",
                False,
            ),
            (
                {"tari": {"view_key": "a" * 63}},
                "local",
                ("local", "", "auto", "false", "a" * 63, "", "auto", "false"),
                b"tari.view_key",
                False,
            ),
            (
                {"tari": {"view_key": "g" * 64}},
                "local",
                ("local", "", "auto", "false", "g" * 64, "", "auto", "false"),
                b"tari.view_key",
                False,
            ),
            (
                {"tari": {"view_key": KEY, "payout_scan_birthday": -1}},
                "local",
                ("local", "", "auto", "false", KEY, "", "-1", "false"),
                b"payout_scan_birthday",
                True,
            ),
            (
                {"tari": {"view_key": KEY, "payout_scan_birthday": 2001}},
                "local",
                ("local", "", "auto", "false", KEY, "", "2001", "false"),
                b"no later than today",
                True,
            ),
            (
                {"tari": {"view_key": KEY, "payout_scan_birthday": "000000"}},
                "local",
                ("local", "", "auto", "false", KEY, "", "000000", "false"),
                b"days since 2022",
                True,
            ),
        ]
        for document, tari_mode, expected, message, dated in cases:
            with self.subTest(document=document):
                selected = self.compare(
                    document, tari_mode, extra={"PAYOUT_SETTINGS_EPOCH": today_epoch}
                )
                self.assertEqual(selected[0].returncode, 1)
                self.assertEqual(self.state(selected[0]), expected)
                self.assertIn(message, selected[0].stderr)
                self.assertEqual(selected[1].count(b"date:+%s\n"), int(dated))
                self.assertNotIn(b"validate:", selected[1])

    def test_date_and_validator_status_keep_err_traps_and_order(self):
        document = {"tari": {"view_key": KEY, "payout_scan_birthday": 1000}}
        selected = self.compare(
            document,
            extra={"PAYOUT_SETTINGS_DATE_RC": "9", "PAYOUT_SETTINGS_ERR_TRAP": "1"},
        )
        self.assertEqual(selected[0].returncode, 0)
        self.assertEqual(selected[1].count(b"date:+%s\n"), 1)
        self.assertEqual(selected[1].count(b"validate:"), 1)
        self.assertGreaterEqual(selected[2].count(b"err:9\n"), 1)
        selected = self.compare(
            {}, extra={"PAYOUT_SETTINGS_VALIDATE_RC": "9", "PAYOUT_SETTINGS_ERR_TRAP": "1"}
        )
        self.assertEqual(selected[0].returncode, 9)
        self.assertEqual(selected[1].count(b"validate:"), 1)
        self.assertGreaterEqual(selected[2].count(b"err:9\n"), 1)

    def test_unsupported_documents_fall_back_byte_for_byte(self):
        cases = [
            b'{"monero":{"mode":[]}}',
            b'{"monero":{"view_key":{}}}',
            b'{"monero":{"payout_scan_height":1.5}}',
            b'{"tari":{"view_key":[]}}',
            b'{"tari":{"spend_public_key":{}}}',
            b'{"tari":{"payout_scan_birthday":1.5}}',
            b'{"tari":{"view_key":"one","view_key":"two"}}',
            b'{"monero":{"view_key":"line\\u0001break"}}',
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
            "mode = sys.argv[1] if len(sys.argv) == 2 else ''\n"
            "open(os.environ['PAYOUT_SETTINGS_HELPER_LOG'], 'a').write(f'{os.environ.get(\"PITHEAD_GO_HELPER\", \"\")}:{mode}:{len(sys.argv)-1}\\n')\n"
            "sys.stdin.buffer.read()\n"
            "sys.stdout.buffer.write(bytes.fromhex(os.environ.get('FAKE_' + mode.upper() + '_HEX', '')))\n"
            "sys.exit(int(os.environ.get('FAKE_' + mode.upper() + '_RC', '125')))\n"
        )
        path.chmod(0o755)
        return path

    def test_refused_malformed_and_missing_hooks_fall_back_without_poison(self):
        raw = self.encoded({"monero": {"mode": "local"}})
        baseline = self.invoke("bash", raw)
        missing = self.invoke("go", raw, extra={"PAYOUT_SETTINGS_WITHOUT_GO_HOOK": "1"})
        self.assertEqual(
            (self.result(missing[0]), missing[1:]), (self.result(baseline[0]), baseline[1:])
        )
        helper_log = self.directory / "helper.log"
        helper = self.make_helper("fake-helper")
        monero_ok = b"4\0local\0\0auto\0false\0\0"
        tari_ok = KEY.encode() + b"\0\0" + b"1000\0false\0\0"
        cases = [
            (raw, b"", b"", b"", {"FAKE_MONERO_RC": "125"}),
            (raw, b"4\0poison\0", b"", b"", {}),
            (raw, b"4\0local\0\0auto\0false\0\0extra\0", b"", b"", {}),
            (raw, monero_ok, b"poison\0", b"", {}),
            (raw, monero_ok, b"\0\0auto\0false\0\0extra\0", b"", {}),
            (
                self.encoded({"tari": {"view_key": KEY, "payout_scan_birthday": 1000}}),
                monero_ok,
                tari_ok,
                b"\0extra\0",
                {},
            ),
        ]
        for index, (case_raw, monero, tari, birthday, statuses) in enumerate(cases):
            helper_log.write_text("")
            with self.subTest(index=index):
                selected = self.compare(
                    case_raw,
                    native=False,
                    binary=helper,
                    extra={
                        "PAYOUT_SETTINGS_HELPER_LOG": str(helper_log),
                        "FAKE_MONERO_HEX": monero.hex(),
                        "FAKE_MONERO_RC": "0",
                        "FAKE_TARI_HEX": tari.hex(),
                        "FAKE_TARI_RC": "0" if tari else "125",
                        "FAKE_BIRTHDAY_HEX": birthday.hex(),
                        "FAKE_BIRTHDAY_RC": "0" if birthday else "125",
                        **statuses,
                    },
                )
                self.assertNotIn(b"poison", selected[0].stdout)
                log = helper_log.read_text()
                self.assertNotIn(KEY, log)
                self.assertIn("config-payout-settings:monero:1", log)

    def test_private_helper_protocols_and_silent_refusals(self):
        docs = b"https://docs.example"
        raw = self.encoded(
            {
                "monero": {"mode": "local", "view_key": KEY},
                "tari": {"view_key": KEY, "payout_scan_birthday": 1000},
            }
        )
        monero = self.helper("monero", [raw, docs, b"0"])
        self.assertEqual((monero.returncode, monero.stderr), (0, b""))
        self.assertEqual(monero.stdout.split(b"\0")[:2], [b"4", b"local"])
        tari = self.helper("tari", [raw, b"local", docs, b"0"])
        self.assertEqual((tari.returncode, tari.stderr), (0, b""))
        self.assertEqual(tari.stdout.split(b"\0")[0], KEY.encode())
        birthday = self.helper("birthday", [b"2001", b"2000", b"0"])
        self.assertEqual((birthday.returncode, birthday.stderr), (0, b""))
        self.assertIn(b"no later than today", birthday.stdout)
        for mode, parts in [
            ("monero", [b"{}", docs, b"9"]),
            ("tari", [b"{}", b"local", docs, b"9"]),
            ("birthday", [b"auto", b"1", b"9"]),
        ]:
            refused = self.helper(mode, parts)
            self.assertEqual(self.result(refused), (125, b"", b""))


if __name__ == "__main__":
    unittest.main(verbosity=2)
