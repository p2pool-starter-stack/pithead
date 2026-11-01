import json
import os
import shutil
import stat
import subprocess
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
ADAPTER = ROOT / "tests/go-parity/config_persistence_reference.sh"
GO_BINARY = ROOT / "go/bin/pithead"
BASH = shutil.which("bash")
if BASH is None:
    raise RuntimeError("bash is required")


class ConfigPersistenceParityTests(unittest.TestCase):
    def setUp(self):
        cache = ROOT / ".go-cache"
        cache.mkdir(exist_ok=True)
        self.scratch = tempfile.TemporaryDirectory(dir=cache)
        self.addCleanup(self.scratch.cleanup)
        self.directory = Path(self.scratch.name)

    def work(self, name, raw):
        path = self.directory / name
        path.mkdir()
        target = path / "config.json"
        target.write_bytes(raw)
        target.chmod(0o640)
        return path

    def environment(self, implementation, binary=None, extra=None):
        env = {key: value for key, value in os.environ.items() if not key.startswith("PITHEAD_")}
        env.pop("BASH_ENV", None)
        env.update(
            CONFIG_PERSISTENCE_PARITY_IMPL=implementation,
            CONFIG_PERSISTENCE_CALL_LOG="calls",
            PITHEAD_GO_BINARY=str(binary or GO_BINARY),
            NO_COLOR="1",
        )
        env.update(extra or {})
        return env

    def invoke(self, implementation, work, operation, *args, binary=None, extra=None):
        completed = subprocess.run(  # noqa: S603
            [BASH, str(ADAPTER), str(ROOT), str(work), operation, *args],
            env=self.environment(implementation, binary, extra),
            capture_output=True,
            check=False,
            timeout=15,
        )
        return completed.returncode, completed.stdout, completed.stderr, self.state(work)

    def state(self, work):
        def entry(name):
            path = work / name
            if not path.exists():
                return None
            return path.read_bytes(), stat.S_IMODE(path.stat().st_mode)

        calls = (work / "calls").read_bytes() if (work / "calls").exists() else b""
        return tuple(
            entry(name) for name in ("config.json", "config.json.tmp", "alt.json", "defaults.tmp")
        ) + (calls,)

    def compare(self, name, operation, raw, *args, binary=None, extra=None, prepare=None):
        baseline = self.work(name + "-bash", raw)
        selected = self.work(name + "-go", raw)
        if prepare:
            prepare(baseline)
            prepare(selected)
        expected = self.invoke("bash", baseline, operation, *args, extra=extra)
        actual = self.invoke("go", selected, operation, *args, binary=binary, extra=extra)
        self.assertEqual(actual, expected)
        return actual

    def encoded(self, document):
        return json.dumps(document, ensure_ascii=False, separators=(",", ":")).encode() + b"\n"

    def spy(self, name, body):
        path = self.directory / name
        path.write_text("#!/bin/sh\n" + body)
        path.chmod(0o755)
        return path

    def helper(self, operation, payload):
        env = {key: value for key, value in os.environ.items() if not key.startswith("PITHEAD_")}
        env["PITHEAD_GO_HELPER"] = "config-persistence"
        return subprocess.run(  # noqa: S603
            [str(GO_BINARY), operation],
            env=env,
            input=payload,
            capture_output=True,
            check=False,
            timeout=15,
        )

    def test_credentials_preserve_order_and_arbitrary_strings(self):
        raw = b'{"first":1,"monero":{"wallet_address":"wallet"},"last":{"x":true}}\n'
        cases = (
            ("ordinary", "rpc-user", "rpc-password"),
            ("unicode", "usér 東京", "päss 🐢"),
            ("quotes", "user\"\\'$", "line one\nline two\tend"),
        )
        for name, user, password in cases:
            with self.subTest(name=name):
                result = self.compare(name, "credentials", raw, user, password)
                self.assertEqual(result[0], 0)
                document = json.loads(result[3][0][0])
                self.assertEqual(document["monero"]["node_username"], user)
                self.assertEqual(document["monero"]["node_password"], password)
                self.assertEqual(result[3][0][1], 0o600)
                self.assertIsNone(result[3][1])
                self.assertNotIn(password.encode(), result[1] + result[2])

    def test_credentials_create_missing_or_null_monero_object(self):
        for name, document in (("missing", {}), ("null", {"monero": None})):
            with self.subTest(name=name):
                result = self.compare(
                    "credentials-" + name, "credentials", self.encoded(document), "user", "pass"
                )
                self.assertEqual(json.loads(result[3][0][0])["monero"]["node_password"], "pass")

    def test_credentials_unsupported_shapes_and_floats_fall_back(self):
        cases = (
            ("false", b'{"monero":false}\n'),
            ("array", b'{"monero":[]}\n'),
            ("float", b'{"measurement":1.5,"monero":{}}\n'),
        )
        for name, raw in cases:
            with self.subTest(name=name):
                self.compare("credentials-" + name, "credentials", raw, "user", "pass")

    def test_credentials_dry_run_is_byte_identical(self):
        raw = b'{ "monero" : {} }\n'
        result = self.compare(
            "credentials-dry",
            "credentials",
            raw,
            "secret-user",
            "secret-pass",
            extra={"CONFIG_PERSISTENCE_DRY_RUN": "1"},
        )
        self.assertEqual(result, (0, b"", b"", ((raw, 0o640), None, None, None, b"")))

    def test_only_dry_run_one_skips_credentials_and_defaults_never_skip(self):
        raw = b'{"monero":{}}\n'
        credentials = self.compare(
            "credentials-dry-two",
            "credentials",
            raw,
            "user",
            "pass",
            extra={"CONFIG_PERSISTENCE_DRY_RUN": "2"},
        )
        self.assertEqual(json.loads(credentials[3][0][0])["monero"]["node_password"], "pass")
        defaults = self.compare(
            "defaults-dry-one",
            "defaults",
            b"{}\n",
            extra={"CONFIG_PERSISTENCE_DRY_RUN": "1"},
        )
        self.assertTrue(json.loads(defaults[3][0][0])["tor"]["auto_heal"])

    def test_credentials_temp_mode_matches_at_first_move(self):
        raw = b'{"monero":{}}\n'
        fresh = self.compare(
            "credentials-fresh-mode",
            "credentials",
            raw,
            "user",
            "pass",
            extra={"CONFIG_PERSISTENCE_TRACE_MV": "1"},
        )
        self.assertEqual(fresh[1], b"mv-mode:600\n")

        def preexisting(work):
            target = work / "config.json.tmp"
            target.write_bytes(b"old-secret")
            target.chmod(0o644)

        existing = self.compare(
            "credentials-existing-mode",
            "credentials",
            raw,
            "user",
            "pass",
            extra={"CONFIG_PERSISTENCE_TRACE_MV": "1"},
            prepare=preexisting,
        )
        self.assertEqual(existing[1], b"mv-mode:644\n")

    def test_credentials_write_failures_match_and_clean_up(self):
        raw = b'{"monero":{}}\n'
        for tool in ("mv", "chmod"):
            with self.subTest(tool=tool):
                self.compare(
                    "credentials-" + tool,
                    "credentials",
                    raw,
                    "secret-user",
                    "secret-pass",
                    extra={"CONFIG_PERSISTENCE_FAIL_TOOL": tool},
                )
        self.compare(
            "credentials-mv-trap",
            "credentials",
            raw,
            "secret-user",
            "secret-pass",
            extra={"CONFIG_PERSISTENCE_FAIL_TOOL": "mv", "CONFIG_PERSISTENCE_ERR_TRAP": "1"},
        )

    def test_appliance_defaults_scalar_cases_match(self):
        cases = (
            ("absent", {}),
            ("tor-null", {"tor": {"auto_heal": None}}),
            ("tor-false", {"tor": {"auto_heal": False}}),
            ("password", {"dashboard": {"auth": {"password": "pass"}}}),
            ("password-empty", {"dashboard": {"auth": {"password": ""}}}),
            (
                "control-false",
                {"dashboard": {"auth": {"password": "pass"}, "control": {"enabled": False}}},
            ),
        )
        for name, document in cases:
            with self.subTest(name=name):
                result = self.compare("defaults-" + name, "defaults", self.encoded(document))
                self.assertEqual(result[0], 0)
                self.assertEqual(result[3][4], b"provider:new:appliance\n")

    def test_appliance_password_coercions_and_shapes_match(self):
        values = (None, False, "", "true", 17, [], {})
        for index, value in enumerate(values):
            with self.subTest(value=value):
                raw = self.encoded({"dashboard": {"auth": {"password": value}}})
                self.compare(f"defaults-password-{index}", "defaults", raw)
        for name, raw in (
            ("tor-false-parent", b'{"tor":false}\n'),
            ("tor-array-parent", b'{"tor":[]}\n'),
            ("dashboard-false-parent", b'{"dashboard":false}\n'),
        ):
            with self.subTest(name=name):
                self.compare("defaults-" + name, "defaults", raw)

    def test_appliance_explicit_path_and_provider_status_match(self):
        raw = b'{"original":true}\n'

        def alternate(work):
            (work / "alt.json").write_bytes(b'{"dashboard":{"auth":{"password":"pass"}}}\n')

        for status in ("0", "17"):
            with self.subTest(status=status):
                result = self.compare(
                    "defaults-alt-" + status,
                    "defaults",
                    raw,
                    "alt.json",
                    extra={"CONFIG_PERSISTENCE_PROVIDER_RC": status},
                    prepare=alternate,
                )
                self.assertEqual(result[3][0], (raw, 0o640))
                self.assertEqual(result[3][4], b"provider:new:appliance\n")

    def test_appliance_file_failures_match(self):
        raw = b'{"dashboard":{"auth":{"password":"pass"}}}\n'
        for tool in ("mktemp", "mv"):
            with self.subTest(tool=tool):
                self.compare(
                    "defaults-" + tool,
                    "defaults",
                    raw,
                    extra={"CONFIG_PERSISTENCE_FAIL_TOOL": tool},
                )

    def test_private_helper_frames_and_refusals(self):
        credentials = b'{"monero":{}}\0user\0pass\0' + b"0\0"
        defaults = b'{"tor":{"auto_heal":true},"dashboard":{"control":{"enabled":true}}}'
        appliance = b"{}\0" + defaults + b"\0" + b"0\0"
        result = self.helper("credentials", credentials)
        self.assertEqual(result.returncode, 0)
        self.assertEqual(json.loads(result.stdout[:-1])["monero"]["node_password"], "pass")
        result = self.helper("appliance", appliance)
        self.assertEqual(result.returncode, 0)
        self.assertTrue(json.loads(result.stdout[:-1])["tor"]["auto_heal"])
        for completed in (
            self.helper("credentials", credentials[:-1]),
            self.helper("credentials", credentials + b"x"),
            self.helper("credentials", credentials[:-2] + b"1\0"),
            self.helper("credentials", b'{"measurement":1.5}\0user\0pass\0' + b"0\0"),
            self.helper("appliance", appliance[:-1]),
            self.helper("appliance", b"{}\0bad\0" + b"0\0"),
            self.helper("unknown", b""),
        ):
            self.assertEqual(
                (completed.returncode, completed.stdout, completed.stderr), (125, b"", b"")
            )

    def test_supported_writes_use_native_helpers_without_jq(self):
        forbidden = self.directory / "forbidden"
        forbidden.mkdir()
        marker = self.directory / "jq-called"
        jq = forbidden / "jq"
        jq.write_text('#!/bin/sh\nprintf "called\\n" >>"$PERSISTENCE_JQ_LOG"\nexit 91\n')
        jq.chmod(0o755)
        log = self.directory / "spy.log"
        spy = self.spy(
            "spy",
            '"$PERSISTENCE_REAL_GO" "$@"; rc=$?\n'
            'printf "%s:%s:%s\\n" "${PITHEAD_GO_HELPER:-}" "${1:-}" "$rc" >>"$PERSISTENCE_SPY_LOG"\n'
            "exit $rc\n",
        )
        extra = {
            "PERSISTENCE_REAL_GO": str(GO_BINARY),
            "PERSISTENCE_SPY_LOG": str(log),
            "PERSISTENCE_JQ_LOG": str(marker),
            "PATH": str(forbidden) + os.pathsep + os.environ.get("PATH", os.defpath),
        }
        work = self.work("native-credentials", b'{"monero":{}}\n')
        self.assertEqual(
            self.invoke("go", work, "credentials", "user", "pass", binary=spy, extra=extra)[0], 0
        )
        work = self.work("native-appliance", b"{}\n")
        self.assertEqual(self.invoke("go", work, "defaults", binary=spy, extra=extra)[0], 0)
        self.assertEqual(
            log.read_text().splitlines(),
            ["config-persistence:credentials:0", "config-persistence:appliance:0"],
        )
        self.assertFalse(marker.exists())

    def test_missing_bad_and_partial_helpers_fall_back_without_poison(self):
        raw = b'{"monero":{}}\n'
        scripts = (
            ("refused", "exit 125\n"),
            ("malformed", "printf bad; exit 0\n"),
            ("partial", "printf poison; exit 42\n"),
        )
        for name, body in scripts:
            with self.subTest(name=name):
                fake = self.spy(name, body)
                result = self.compare(name, "credentials", raw, "user", "secret", binary=fake)
                self.assertNotIn(b"poison", result[3][0][0])
                self.assertNotIn(b"secret", result[1] + result[2])
        self.compare(
            "missing-helper",
            "credentials",
            raw,
            "user",
            "secret",
            binary=self.directory / "missing-helper",
        )
        self.compare(
            "producer-failure",
            "credentials",
            raw,
            "user",
            "secret",
            extra={"CONFIG_PERSISTENCE_FAIL_TOOL": "cat"},
        )

    def test_invalid_defaults_and_partial_appliance_helper_match(self):
        raw = b"{}\n"
        self.compare(
            "invalid-defaults",
            "defaults",
            raw,
            extra={"CONFIG_PERSISTENCE_DEFAULTS": "bad"},
        )
        fake = self.spy("partial-appliance", "printf poison; exit 42\n")
        result = self.compare("partial-appliance", "defaults", raw, binary=fake)
        self.assertNotIn(b"poison", result[3][0][0])

    def test_config_read_site_extractor_still_accepts_generated_cli(self):
        work = self.work("read-sites", b"{}\n")
        result = self.invoke("go", work, "read-sites")
        self.assertEqual(result[0], 0)
        self.assertNotIn(b"bad:", result[1])
        self.assertIn(b"status:0\n", result[1])


if __name__ == "__main__":
    unittest.main(verbosity=2)
