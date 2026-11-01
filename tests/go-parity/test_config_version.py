import json
import os
import re
import shutil
import stat
import subprocess
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
ADAPTER = ROOT / "tests/go-parity/config_version_reference.sh"
GO_BINARY = ROOT / "go/bin/pithead"
BASH = shutil.which("bash")
if BASH is None:
    raise RuntimeError("bash is required")


class ConfigVersionParityTests(unittest.TestCase):
    def setUp(self):
        cache = ROOT / ".go-cache"
        cache.mkdir(exist_ok=True)
        self.scratch = tempfile.TemporaryDirectory(dir=cache)
        self.addCleanup(self.scratch.cleanup)
        self.directory = Path(self.scratch.name)

    def work(self, name, version=b"2.1.0\n", config=b"{}\n"):
        path = self.directory / name
        path.mkdir()
        (path / "VERSION").write_bytes(version)
        (path / "config.json").write_bytes(config)
        (path / "config.json").chmod(0o640)
        return path

    def environment(self, implementation, binary=None, extra=None):
        env = {key: value for key, value in os.environ.items() if not key.startswith("PITHEAD_")}
        env.pop("BASH_ENV", None)
        env.update(
            CONFIG_VERSION_PARITY_IMPL=implementation,
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
        target = work / "config.json"
        leftovers = sorted(path.name for path in work.glob("config.json.version.*"))
        mode = stat.S_IMODE(target.stat().st_mode) if target.exists() else None
        return (
            completed.returncode,
            completed.stdout,
            completed.stderr,
            target.read_bytes(),
            mode,
            leftovers,
        )

    def compare(self, name, operation, *args, version=b"2.1.0\n", config=b"{}\n", extra=None):
        baseline = self.work(f"{name}-bash", version, config)
        selected = self.work(f"{name}-go", version, config)
        expected = self.invoke("bash", baseline, operation, *args, extra=extra)
        actual = self.invoke("go", selected, operation, *args, extra=extra)
        self.assertEqual(actual, expected)
        return actual

    def spy(self, name, body):
        path = self.directory / name
        path.write_text("#!/bin/sh\n" + body)
        path.chmod(0o755)
        return path

    def helper(self, operation, *args, data=b"", binary=None):
        env = {key: value for key, value in os.environ.items() if not key.startswith("PITHEAD_")}
        env.pop("BASH_ENV", None)
        env["PITHEAD_GO_HELPER"] = "config-version"
        return subprocess.run(  # noqa: S603
            [str(binary or GO_BINARY), operation, *args],
            env=env,
            input=data,
            capture_output=True,
            check=False,
            timeout=15,
        )

    def test_release_version_normalization_matches(self):
        cases = (
            (b" 2.1.0-pre.1+build \r\n", 0, b"2.1.0"),
            (b"1.2.3+meta\n", 0, b"1.2.3"),
            (b"v2.1.0\n", 1, b""),
            (b"2.1\n", 1, b""),
            (b"10000.1.1\n", 1, b""),
            (b"\n", 1, b""),
        )
        for index, (version, rc, output) in enumerate(cases):
            with self.subTest(version=version):
                result = self.compare(f"normalize-{index}", "code", version=version)
                self.assertEqual(result[:3], (rc, output, b""))

    def test_missing_release_version_warns_and_leaves_config_unchanged(self):
        raw = b'{"secret":"never-log-this"}\n'
        baseline = self.work("missing-version-bash", config=raw)
        selected = self.work("missing-version-go", config=raw)
        (baseline / "VERSION").unlink()
        (selected / "VERSION").unlink()
        expected = self.invoke("bash", baseline, "stamp")
        actual = self.invoke("go", selected, "stamp")
        self.assertEqual(actual, expected)
        self.assertEqual(actual[3], raw)
        self.assertIn(b"Could not read the release version", actual[2])
        self.assertNotIn(b"never-log-this", actual[2])

    def test_version_predicates_match_real_bash_helpers(self):
        for value, rc in (
            ("0.0.0", 0),
            ("9999.9999.9999", 0),
            ("01.2.3", 0),
            ("v1.2.3", 1),
            ("1.2", 1),
            ("10000.1.1", 1),
        ):
            with self.subTest(value=value):
                result = self.compare("ok-" + value.replace("/", "_"), "ok", value)
                self.assertEqual(result[0], rc)
        for newer, older, rc in (
            ("2.1.0", "2.0.9", 0),
            ("2.0.9", "2.1.0", 1),
            ("2.1.0", "2.1.0", 1),
        ):
            with self.subTest(newer=newer, older=older):
                result = self.compare(f"newer-{newer}-{older}", "newer", newer, older)
                self.assertEqual(result[0], rc)

    def test_stamp_plans_match_and_preserve_bytes_when_no_write_is_needed(self):
        cases = (
            ("absent-dry", b'{"alpha":1}\n', "1", b""),
            ("equal", b'{ "config_version" : "2.1.0", "alpha" : 1 }\n', "0", b""),
            (
                "newer",
                b'{"config_version":"9.9.9","secret":"never-log-this"}\n',
                "0",
                b"written by pithead 9.9.9",
            ),
        )
        for name, raw, dry_run, warning in cases:
            with self.subTest(name=name):
                result = self.compare(
                    name, "stamp", config=raw, extra={"CONFIG_VERSION_DRY_RUN": dry_run}
                )
                self.assertEqual(result[3], raw)
                self.assertIn(warning, result[2])
                self.assertNotIn(b"never-log-this", result[2])

    def test_stamp_writes_jq_ordered_json_and_secures_mode(self):
        cases = (
            ("absent", b'{"alpha":1,"nested":{"x":true}}\n'),
            ("null", b'{"config_version":null,"alpha":1}\n'),
            ("false", b'{"config_version":false,"alpha":1}\n'),
            ("malformed", b'{"config_version":"old","alpha":1}\n'),
            ("numeric", b'{"config_version":17,"alpha":1}\n'),
            ("older", b'{"config_version":"2.0.0","alpha":1}\n'),
        )
        for name, raw in cases:
            with self.subTest(name=name):
                result = self.compare(
                    name, "stamp", config=raw, extra={"CONFIG_VERSION_DRY_RUN": "0"}
                )
                self.assertEqual(result[0], 0)
                self.assertEqual(json.loads(result[3])["config_version"], "2.1.0")
                self.assertEqual(result[4:], (0o600, []))

    def test_helper_refusal_and_bad_output_fall_back_without_partial_promotion(self):
        scripts = (
            ("refused", "exit 125\n"),
            ("malformed", "printf 'bad-output'; exit 0\n"),
            ("producer", "exit 42\n"),
        )
        raw = b'{"alpha":1}\n'
        for name, body in scripts:
            with self.subTest(name=name):
                fake = self.spy(name, body)
                baseline = self.work(name + "-baseline", config=raw)
                selected = self.work(name + "-selected", config=raw)
                expected = self.invoke(
                    "bash", baseline, "stamp", extra={"CONFIG_VERSION_DRY_RUN": "0"}
                )
                actual = self.invoke(
                    "go", selected, "stamp", binary=fake, extra={"CONFIG_VERSION_DRY_RUN": "0"}
                )
                self.assertEqual(actual, expected)
        baseline = self.work("missing-binary-baseline", config=raw)
        selected = self.work("missing-binary-selected", config=raw)
        expected = self.invoke("bash", baseline, "stamp", extra={"CONFIG_VERSION_DRY_RUN": "0"})
        actual = self.invoke(
            "go",
            selected,
            "stamp",
            binary=self.directory / "missing-binary",
            extra={"CONFIG_VERSION_DRY_RUN": "0"},
        )
        self.assertEqual(actual, expected)

    def test_atomic_write_failures_warn_preserve_original_and_clean_temp(self):
        raw = b'{"alpha":1}\n'
        for tool in ("mktemp", "chmod", "chown", "mv"):
            with self.subTest(tool=tool):
                result = self.compare(
                    "fail-" + tool,
                    "stamp",
                    config=raw,
                    extra={"CONFIG_VERSION_DRY_RUN": "0", "CONFIG_VERSION_FAIL_TOOL": tool},
                )
                self.assertEqual(result[0], 0)
                self.assertEqual(result[3], raw)
                self.assertIn(b"Could not write config_version", result[2])
                self.assertEqual(result[5], [])

    def test_unavailable_owner_lookup_still_promotes(self):
        result = self.compare(
            "stat-failure",
            "stamp",
            config=b'{"alpha":1}\n',
            extra={"CONFIG_VERSION_DRY_RUN": "0", "CONFIG_VERSION_FAIL_TOOL": "stat"},
        )
        self.assertEqual((result[0], result[4], result[5]), (0, 0o600, []))

    def test_private_helper_protocol_rejects_bad_frames_and_args(self):
        cases = (
            self.helper("normalize"),
            self.helper("ok", "1.2.3", "extra"),
            self.helper("plan", data=b"{}\0"),
            self.helper("plan", data=b"{}\0" + b"2.1.0\0" + b"1\0"),
            self.helper("json", data=b"{}\0" + b"2.1.0\0" + b"0\0trailing"),
            self.helper("unknown"),
        )
        for completed in cases:
            self.assertEqual(
                (completed.returncode, completed.stdout, completed.stderr), (125, b"", b"")
            )

    def test_private_helper_scalar_plan_and_json_frames(self):
        normalized = self.helper("normalize", "2.1.0-pre.1")
        self.assertEqual((normalized.returncode, normalized.stdout), (0, b"2.1.0\0"))
        invalid = self.helper("ok", "v2.1.0")
        self.assertEqual((invalid.returncode, invalid.stdout), (1, b""))
        raw = b'{"alpha":1}'
        framed = raw + b"\0" + b"2.1.0\0" + b"0\0"
        plan = self.helper("plan", data=framed)
        self.assertEqual((plan.returncode, plan.stdout), (0, b"2.0.0\0false\0false\0false\0"))
        rendered = self.helper("json", data=framed)
        self.assertEqual(rendered.returncode, 0)
        self.assertTrue(rendered.stdout.endswith(b"\n\0"))
        self.assertEqual(json.loads(rendered.stdout[:-1])["config_version"], "2.1.0")

    def test_scalar_poison_and_truncation_fall_back_to_bash(self):
        scripts = (
            ("unterminated", "printf '2.1.0\\0junk'; exit 0\n"),
            ("extra-field", "printf '2.1.0\\0junk\\0'; exit 0\n"),
            ("truncated", "printf '2.1.0'; exit 0\n"),
            ("invalid-poison", "printf 'poison\\0'; exit 1\n"),
        )
        for name, body in scripts:
            with self.subTest(name=name):
                fake = self.spy("scalar-" + name, body)
                baseline = self.work(name + "-scalar-baseline", version=b"2.1.0-pre\n")
                selected = self.work(name + "-scalar-selected", version=b"2.1.0-pre\n")
                expected = self.invoke("bash", baseline, "code")
                actual = self.invoke("go", selected, "code", binary=fake)
                self.assertEqual(actual, expected)

    def test_partial_plan_does_not_publish_fields_before_fallback(self):
        fake = self.spy(
            "partial-plan",
            'if [ "${1:-}" = plan ]; then printf "9.9.9\\0true\\0"; exit 0; fi\n'
            'exec "$CONFIG_VERSION_REAL_GO" "$@"\n',
        )
        raw = b'{"alpha":1}\n'
        baseline = self.work("partial-plan-baseline", config=raw)
        selected = self.work("partial-plan-selected", config=raw)
        expected = self.invoke("bash", baseline, "stamp")
        actual = self.invoke(
            "go", selected, "stamp", binary=fake, extra={"CONFIG_VERSION_REAL_GO": str(GO_BINARY)}
        )
        self.assertEqual(actual, expected)

    def test_unwritable_native_target_matches_legacy_failure(self):
        raw = b'{"alpha":1}\n'
        baseline = self.work("blocked-baseline", config=raw)
        selected = self.work("blocked-selected", config=raw)
        (baseline / "blocked").write_bytes(b"")
        (selected / "blocked").write_bytes(b"")
        (baseline / "blocked").chmod(0)
        (selected / "blocked").chmod(0)
        extra = {"CONFIG_VERSION_FAIL_TOOL": "write-target"}
        expected = self.invoke("bash", baseline, "stamp", extra=extra)
        actual = self.invoke("go", selected, "stamp", extra=extra)
        self.assertEqual(actual[:2] + actual[3:], expected[:2] + expected[3:])
        self.assertEqual(
            re.sub(rb"line \d+", b"line N", actual[2]),
            re.sub(rb"line \d+", b"line N", expected[2]),
        )
        self.assertEqual(actual[3], raw)

    def test_native_helper_runs_without_jq_for_supported_stamp(self):
        log = self.directory / "spy.log"
        forbidden = self.directory / "forbidden"
        forbidden.mkdir()
        marker = self.directory / "jq-called"
        jq = forbidden / "jq"
        jq.write_text('#!/bin/sh\nprintf "called\\n" >>"$CONFIG_VERSION_JQ_LOG"\nexit 91\n')
        jq.chmod(0o755)
        spy = self.spy(
            "spy",
            '"$CONFIG_VERSION_REAL_GO" "$@"; rc=$?\n'
            'printf "%s:%s:%s\\n" "${PITHEAD_GO_HELPER:-}" "${1:-}" "$rc" >>"$CONFIG_VERSION_SPY_LOG"\n'
            "exit $rc\n",
        )
        raw = b'{"alpha":1,"secret":"never-log-this"}\n'
        work = self.work("native", config=raw)
        result = self.invoke(
            "go",
            work,
            "stamp",
            binary=spy,
            extra={
                "CONFIG_VERSION_DRY_RUN": "0",
                "CONFIG_VERSION_REAL_GO": str(GO_BINARY),
                "CONFIG_VERSION_SPY_LOG": str(log),
                "CONFIG_VERSION_JQ_LOG": str(marker),
                "PATH": str(forbidden) + os.pathsep + os.environ.get("PATH", os.defpath),
            },
        )
        self.assertEqual(result[0], 0)
        calls = log.read_text().splitlines()
        self.assertTrue(calls)
        self.assertTrue(all(call.startswith("config-version:") for call in calls))
        self.assertNotIn("never-log-this", log.read_text())
        self.assertFalse(marker.exists())

    def test_float_document_uses_legacy_jq_after_native_json_refusal(self):
        log = self.directory / "float.log"
        spy = self.spy(
            "float-spy",
            '"$CONFIG_VERSION_REAL_GO" "$@"; rc=$?\n'
            'printf "%s:%s:%s\\n" "${PITHEAD_GO_HELPER:-}" "${1:-}" "$rc" >>"$CONFIG_VERSION_SPY_LOG"\n'
            "exit $rc\n",
        )
        raw = b'{"measurement":1.5,"alpha":1}\n'
        baseline = self.work("float-baseline", config=raw)
        selected = self.work("float-selected", config=raw)
        expected = self.invoke("bash", baseline, "stamp", extra={"CONFIG_VERSION_DRY_RUN": "0"})
        actual = self.invoke(
            "go",
            selected,
            "stamp",
            binary=spy,
            extra={
                "CONFIG_VERSION_DRY_RUN": "0",
                "CONFIG_VERSION_REAL_GO": str(GO_BINARY),
                "CONFIG_VERSION_SPY_LOG": str(log),
            },
        )
        self.assertEqual(actual, expected)
        self.assertIn("config-version:plan:0", log.read_text().splitlines())
        self.assertIn("config-version:json:125", log.read_text().splitlines())

    def test_partial_native_json_is_truncated_before_legacy_fallback(self):
        fake = self.spy(
            "partial-json",
            'if [ "${1:-}" = json ]; then printf "poison"; exit 42; fi\n'
            'exec "$CONFIG_VERSION_REAL_GO" "$@"\n',
        )
        raw = b'{"alpha":1}\n'
        baseline = self.work("partial-baseline", config=raw)
        selected = self.work("partial-selected", config=raw)
        expected = self.invoke("bash", baseline, "stamp", extra={"CONFIG_VERSION_DRY_RUN": "0"})
        actual = self.invoke(
            "go",
            selected,
            "stamp",
            binary=fake,
            extra={
                "CONFIG_VERSION_DRY_RUN": "0",
                "CONFIG_VERSION_REAL_GO": str(GO_BINARY),
            },
        )
        self.assertEqual(actual, expected)
        self.assertNotIn(b"poison", actual[3])


if __name__ == "__main__":
    unittest.main(verbosity=2)
