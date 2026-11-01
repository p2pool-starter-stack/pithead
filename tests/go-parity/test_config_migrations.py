import json
import os
import shutil
import stat
import subprocess
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
ADAPTER = ROOT / "tests/go-parity/config_migrations_reference.sh"
GO_BINARY = ROOT / "go/bin/pithead"
BASH = shutil.which("bash")
if BASH is None:
    raise RuntimeError("bash is required")


class ConfigMigrationsParityTests(unittest.TestCase):
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
            CONFIG_MIGRATIONS_PARITY_IMPL=implementation,
            PITHEAD_GO_BINARY=str(binary or GO_BINARY),
            NO_COLOR="1",
        )
        env.update(extra or {})
        return env

    def invoke(self, implementation, work, operation, binary=None, extra=None):
        completed = subprocess.run(  # noqa: S603
            [BASH, str(ADAPTER), str(ROOT), str(work), operation],
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

        return entry("config.json"), entry("config.json.bak-1x"), entry("config.json.tmp")

    def compare(self, name, operation, document, *, dry=False, binary=None, extra=None):
        raw = document if isinstance(document, bytes) else self.encoded(document)
        baseline = self.work(name + "-bash", raw)
        selected = self.work(name + "-go", raw)
        case_env = {"CONFIG_MIGRATIONS_DRY_RUN": "1" if dry else "0", **(extra or {})}
        expected = self.invoke("bash", baseline, operation, extra=case_env)
        actual = self.invoke("go", selected, operation, binary, case_env)
        self.assertEqual(actual, expected)
        return actual

    def encoded(self, document):
        return json.dumps(document, ensure_ascii=False, separators=(",", ":")).encode() + b"\n"

    def spy(self, name, body):
        path = self.directory / name
        path.write_text("#!/bin/sh\n" + body)
        path.chmod(0o755)
        return path

    def test_worker_relocations_and_stable_order_match(self):
        cases = (
            (
                "workers",
                {"first": 1, "dashboard": {"workers": [{"name": "rig", "host": "rig"}]}, "last": 2},
            ),
            (
                "same-workers",
                {
                    "dashboard": {"workers": [{"name": "rig", "host": "rig"}]},
                    "workers": {"api_port": 8080, "list": [{"name": "rig", "host": "rig"}]},
                },
            ),
            ("xvb-missing", {"xmrig_proxy": {"enabled": False, "url": "pool", "donor_id": "id"}}),
            ("xvb-null", {"xvb": None, "xmrig_proxy": {"enabled": False}}),
            ("member-null", {"xvb": {"enabled": None}, "xmrig_proxy": {"enabled": None}}),
            (
                "object-equality",
                {
                    "xvb": {"url": {"second": 2, "first": 1}},
                    "xmrig_proxy": {"url": {"first": 1, "second": 2}},
                },
            ),
            (
                "v1-defaults",
                {
                    "xvb": {"enabled": False, "url": "custom", "donor_id": "mine"},
                    "xmrig_proxy": {
                        "enabled": True,
                        "url": "na.xmrvsbeast.com:4247",
                        "donor_id": "auto",
                    },
                },
            ),
            ("unknown-alias", {"xmrig_proxy": {"unknown": "drop"}, "xvb": {"enabled": False}}),
        )
        for name, document in cases:
            with self.subTest(name=name):
                result = self.compare(name, "workers", document)
                self.assertEqual(result[0], 0)
                migrated = json.loads(result[3][0][0])
                self.assertNotIn("xmrig_proxy", migrated)
                self.assertNotIn("workers", migrated.get("dashboard", {}))
                self.assertEqual(result[3][0][1], 0o600)
                self.assertEqual(result[3][1][1], 0o640)
                self.assertIsNone(result[3][2])

    def test_empty_and_absent_legacy_keys_match(self):
        cases = (
            ("absent", {"workers": {"list": []}}, False),
            ("empty-workers", {"dashboard": {"workers": []}}, True),
            ("empty-alias", {"xmrig_proxy": {}, "xvb": {}}, True),
        )
        for name, document, changed in cases:
            with self.subTest(name=name):
                raw = self.encoded(document)
                result = self.compare(name, "workers", raw)
                self.assertEqual(result[0], 0)
                if changed:
                    self.assertIsNotNone(result[3][1])
                else:
                    self.assertEqual(result[3], ((raw, 0o640), None, None))

    def test_conflicts_fail_before_dry_run_and_preserve_bytes(self):
        cases = (
            (
                "workers-conflict",
                {
                    "dashboard": {"workers": [{"name": "old"}]},
                    "workers": {"list": [{"name": "new"}]},
                },
                b"workers.list[] and dashboard.workers[]",
            ),
            (
                "xvb-conflict",
                {"xmrig_proxy": {"url": "old"}, "xvb": {"url": "new"}},
                b"xvb.url and xmrig_proxy.url",
            ),
            (
                "missing-versus-null",
                {"xmrig_proxy": {"enabled": False}, "xvb": {"enabled": None}},
                b"xvb.enabled and xmrig_proxy.enabled",
            ),
        )
        for name, document, message in cases:
            with self.subTest(name=name):
                raw = self.encoded(document)
                result = self.compare(name, "workers", raw, dry=True)
                self.assertEqual(result[0], 1)
                self.assertIn(message, result[2])
                self.assertEqual(result[3], ((raw, 0o640), None, None))

    def test_dry_run_never_migrates_nonconflicting_data(self):
        raw = self.encoded({"dashboard": {"workers": [{"name": "rig"}]}})
        result = self.compare("dry-workers", "workers", raw, dry=True)
        self.assertEqual(result, (0, b"", b"", ((raw, 0o640), None, None)))

    def test_numeric_equality_and_unsupported_shapes_match(self):
        cases = (
            ("numeric-equal", b'{"xmrig_proxy":{"url":1.0},"xvb":{"url":1}}\n'),
            ("alias-array", b'{"xmrig_proxy":[],"xvb":{}}\n'),
            ("dashboard-array", b'{"dashboard":[],"workers":{"list":[]}}\n'),
        )
        for name, raw in cases:
            with self.subTest(name=name):
                self.compare(name, "workers", raw)

    def test_backup_failure_is_fail_closed_only_for_populated_data(self):
        cases = (
            ("populated", {"xmrig_proxy": {"url": "custom"}}, 1, b"Refusing"),
            ("empty", {"xmrig_proxy": {}}, 0, b"leaving them in place"),
        )
        for name, document, status, message in cases:
            with self.subTest(name=name):
                raw = self.encoded(document)
                result = self.compare(
                    "cp-" + name,
                    "workers",
                    raw,
                    extra={"CONFIG_MIGRATIONS_FAIL_TOOL": "cp"},
                )
                self.assertEqual(result[0], status)
                self.assertIn(message, result[2])
                self.assertEqual(result[3], ((raw, 0o640), None, None))

    def test_worker_post_promotion_failure_order_matches(self):
        raw = self.encoded({"xmrig_proxy": {"enabled": False}})
        for tool in ("mv", "chmod", "chown"):
            with self.subTest(tool=tool):
                self.compare(
                    "workers-" + tool,
                    "workers",
                    raw,
                    extra={"CONFIG_MIGRATIONS_FAIL_TOOL": tool},
                )

    def test_worker_migration_is_idempotent_and_keeps_first_backup(self):
        raw = self.encoded({"dashboard": {"workers": [{"name": "rig", "token": "secret"}]}})
        baseline = self.work("repeat-bash", raw)
        selected = self.work("repeat-go", raw)
        first_expected = self.invoke("bash", baseline, "workers")
        first_actual = self.invoke("go", selected, "workers")
        self.assertEqual(first_actual, first_expected)
        second_expected = self.invoke("bash", baseline, "workers")
        second_actual = self.invoke("go", selected, "workers")
        self.assertEqual(second_actual, second_expected)
        self.assertEqual(second_actual[1:3], (b"", b""))
        self.assertEqual(second_actual[3][1][0], raw)

    def test_telegram_shapes_warnings_and_bytes_match(self):
        cases = (
            ("absent", {"telegram": {"enabled": True}}, False),
            ("null", {"telegram": None}, False),
            ("false", {"telegram": {"control": {"enabled": False}}}, False),
            ("true", {"telegram": {"control": {"enabled": True}}}, True),
            ("string-true", {"telegram": {"control": {"enabled": "true"}}}, True),
            ("string-linefeed", {"telegram": {"control": {"enabled": "true\n\n"}}}, True),
            ("string-tab", {"telegram": {"control": {"enabled": "true\t"}}}, False),
            ("string-nul", {"telegram": {"control": {"enabled": "true\0"}}}, True),
        )
        for name, document, warns in cases:
            with self.subTest(name=name):
                raw = self.encoded(document)
                result = self.compare("telegram-" + name, "telegram", raw)
                self.assertEqual(result[0], 0)
                self.assertEqual(b"telegram.control was removed" in result[2], warns)
                if name in ("absent", "null"):
                    self.assertEqual(result[3], ((raw, 0o640), None, None))
                else:
                    self.assertNotIn("control", json.loads(result[3][0][0])["telegram"])

    def test_telegram_dry_run_and_write_failures_match(self):
        raw = self.encoded({"telegram": {"control": {"enabled": True}}})
        dry = self.compare("telegram-dry", "telegram", raw, dry=True)
        self.assertEqual(dry, (0, b"", b"", ((raw, 0o640), None, None)))
        for tool in ("mv", "chmod", "chown"):
            with self.subTest(tool=tool):
                self.compare(
                    "telegram-" + tool,
                    "telegram",
                    raw,
                    extra={"CONFIG_MIGRATIONS_FAIL_TOOL": tool},
                )

    def test_config_read_site_extractor_keeps_removed_path_exception(self):
        work = self.work("read-sites", b"{}\n")
        result = self.invoke("go", work, "read-sites")
        self.assertEqual(result[0], 0)
        self.assertNotIn(b"bad:", result[1])
        self.assertIn(b"status:0\n", result[1])
        self.assertIn(b"telegram.control.enabled", result[1])

    def test_supported_migrations_use_native_helpers_without_jq(self):
        forbidden = self.directory / "forbidden"
        forbidden.mkdir()
        marker = self.directory / "jq-called"
        jq = forbidden / "jq"
        jq.write_text('#!/bin/sh\nprintf "called\\n" >>"$MIGRATION_JQ_LOG"\nexit 91\n')
        jq.chmod(0o755)
        log = self.directory / "spy.log"
        spy = self.spy(
            "spy",
            '"$MIGRATION_REAL_GO" "$@"; rc=$?\n'
            'printf "%s:%s:%s\\n" "${PITHEAD_GO_HELPER:-}" "${1:-}" "$rc" >>"$MIGRATION_SPY_LOG"\n'
            "exit $rc\n",
        )
        extra = {
            "MIGRATION_REAL_GO": str(GO_BINARY),
            "MIGRATION_SPY_LOG": str(log),
            "MIGRATION_JQ_LOG": str(marker),
            "PATH": str(forbidden) + os.pathsep + os.environ.get("PATH", os.defpath),
        }
        work = self.work("native-workers", self.encoded({"xmrig_proxy": {"enabled": False}}))
        self.assertEqual(self.invoke("go", work, "workers", spy, extra)[0], 0)
        work = self.work(
            "native-telegram", self.encoded({"telegram": {"control": {"enabled": True}}})
        )
        self.assertEqual(self.invoke("go", work, "telegram", spy, extra)[0], 0)
        calls = log.read_text().splitlines()
        self.assertEqual(
            calls,
            [
                "config-migrations:workers-plan:0",
                "config-migrations:workers-json:0",
                "config-migrations:telegram-plan:0",
                "config-migrations:telegram-json:0",
            ],
        )
        self.assertFalse(marker.exists())

    def test_bad_helper_protocol_and_partial_json_fall_back_cleanly(self):
        raw = self.encoded({"xmrig_proxy": {"url": "secret-endpoint"}})
        scripts = (
            ("refused", "exit 125\n"),
            ("malformed", "printf bad; exit 0\n"),
            (
                "partial-plan",
                'if [ "${1:-}" = workers-plan ]; then printf "\\0true\\0"; exit 0; fi\n'
                'exec "$MIGRATION_REAL_GO" "$@"\n',
            ),
            (
                "partial",
                'if [ "${1:-}" = workers-json ]; then printf "poison"; exit 42; fi\n'
                'exec "$MIGRATION_REAL_GO" "$@"\n',
            ),
        )
        for name, body in scripts:
            with self.subTest(name=name):
                fake = self.spy(name, body)
                baseline = self.work(name + "-baseline", raw)
                selected = self.work(name + "-selected", raw)
                expected = self.invoke("bash", baseline, "workers")
                actual = self.invoke(
                    "go",
                    selected,
                    "workers",
                    fake,
                    {"MIGRATION_REAL_GO": str(GO_BINARY)},
                )
                self.assertEqual(actual, expected)
                self.assertNotIn(b"poison", actual[3][0][0])
                self.assertNotIn(b"secret-endpoint", actual[1] + actual[2])
        baseline = self.work("missing-helper-baseline", raw)
        selected = self.work("missing-helper-selected", raw)
        expected = self.invoke("bash", baseline, "workers")
        actual = self.invoke("go", selected, "workers", self.directory / "missing-helper")
        self.assertEqual(actual, expected)
        self.compare(
            "producer-failure",
            "workers",
            raw,
            extra={"CONFIG_MIGRATIONS_FAIL_TOOL": "cat"},
        )

    def test_transform_failure_keeps_backup_and_fails_only_for_populated_data(self):
        forbidden = self.directory / "failed-transform"
        forbidden.mkdir()
        jq = forbidden / "jq"
        jq.write_text("#!/bin/sh\nexit 91\n")
        jq.chmod(0o755)
        fake = self.spy(
            "failed-json",
            'if [ "${1:-}" = workers-json ]; then printf poison; exit 42; fi\n'
            'exec "$MIGRATION_REAL_GO" "$@"\n',
        )
        extra = {
            "MIGRATION_REAL_GO": str(GO_BINARY),
            "PATH": str(forbidden) + os.pathsep + os.environ.get("PATH", os.defpath),
        }
        for name, document, status, message in (
            ("populated", {"xmrig_proxy": {"url": "custom"}}, 1, b"Refusing"),
            ("empty", {"xmrig_proxy": {}}, 0, b"Could not migrate"),
        ):
            with self.subTest(name=name):
                raw = self.encoded(document)
                work = self.work("transform-" + name, raw)
                result = self.invoke("go", work, "workers", fake, extra)
                self.assertEqual(result[0], status)
                self.assertIn(message, result[2])
                self.assertEqual(result[3], ((raw, 0o640), (raw, 0o640), None))
                self.assertNotIn(b"poison", result[1] + result[2])


if __name__ == "__main__":
    unittest.main(verbosity=2)
