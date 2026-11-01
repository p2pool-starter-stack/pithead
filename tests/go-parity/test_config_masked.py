import hashlib
import json
import os
import shutil
import stat
import subprocess
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
ADAPTER = ROOT / "tests/go-parity/config_masked_reference.sh"
GO_BINARY = ROOT / "go/bin/pithead"
BASH = shutil.which("bash")
if BASH is None:
    raise RuntimeError("bash is required")

SECRET_PATHS = [
    ["dashboard", "auth", "password"],
    ["telegram", "bot_token"],
    ["workers", "api_token"],
    ["monero", "node_username"],
    ["monero", "node_password"],
    ["monero", "view_key"],
    ["tari", "view_key"],
    ["p2pool", "stratum_password"],
    ["healthchecks", "ping_url"],
    ["notifications", "ntfy", "url"],
    ["notifications", "ntfy", "token"],
    ["xvb", "standby", "source"],
]
SENTINEL = {"__secret__": True}


class ConfigMaskedParityTests(unittest.TestCase):
    def setUp(self):
        cache = ROOT / ".go-cache"
        cache.mkdir(exist_ok=True)
        self.scratch = tempfile.TemporaryDirectory(dir=cache)
        self.addCleanup(self.scratch.cleanup)
        self.directory = Path(self.scratch.name)

    def work(self, name, raw):
        path = self.directory / name
        path.mkdir()
        config = path / "config.json"
        config.write_bytes(raw)
        config.chmod(0o640)
        return path

    def environment(self, implementation, binary=None, extra=None):
        env = {key: value for key, value in os.environ.items() if not key.startswith("PITHEAD_")}
        env.pop("BASH_ENV", None)
        env.update(
            CONFIG_MASKED_PARITY_IMPL=implementation,
            PITHEAD_GO_BINARY=str(binary or GO_BINARY),
            NO_COLOR="1",
        )
        env.update(extra or {})
        return env

    def invoke(self, implementation, work, binary=None, extra=None):
        completed = subprocess.run(  # noqa: S603
            [BASH, str(ADAPTER), str(ROOT), str(work), "render"],
            env=self.environment(implementation, binary, extra),
            capture_output=True,
            check=False,
            timeout=15,
        )
        return completed.returncode, completed.stdout, completed.stderr, self.state(work)

    def entry(self, path):
        try:
            metadata = path.lstat()
        except FileNotFoundError:
            return None
        if stat.S_ISLNK(metadata.st_mode):
            return "symlink", os.readlink(path), stat.S_IMODE(metadata.st_mode)
        raw = path.read_bytes()
        return "file", len(raw), hashlib.sha256(raw).hexdigest(), stat.S_IMODE(metadata.st_mode)

    def state(self, work):
        masked = work / "control/masked"
        calls = (work / "calls").read_bytes() if (work / "calls").exists() else b""
        return (
            self.entry(work / "config.json"),
            self.entry(masked / "config.json"),
            self.entry(masked / ".config.json.tmp"),
            self.entry(masked / "worker-read-tokens.json"),
            calls,
        )

    def compare(self, name, raw, binary=None, extra=None, prepare=None):
        baseline = self.work(name + "-bash", raw)
        selected = self.work(name + "-go", raw)
        if prepare:
            prepare(baseline)
            prepare(selected)
        expected = self.invoke("bash", baseline, extra=extra)
        actual = self.invoke("go", selected, binary=binary, extra=extra)
        self.assertEqual(actual, expected)
        return actual, selected

    def encoded(self, document):
        return json.dumps(document, ensure_ascii=False, separators=(",", ":")).encode() + b"\n"

    def helper(self, raw, paths=SECRET_PATHS, status=b"0", args=()):
        payload = raw + b"\0" + self.encoded(paths).rstrip(b"\n") + b"\0" + status + b"\0"
        env = {key: value for key, value in os.environ.items() if not key.startswith("PITHEAD_")}
        env["PITHEAD_GO_HELPER"] = "config-masked"
        return subprocess.run(  # noqa: S603
            [str(GO_BINARY), *args],
            env=env,
            input=payload,
            capture_output=True,
            check=False,
            timeout=15,
        )

    def executable(self, name, body):
        path = self.directory / name
        path.write_text("#!/bin/sh\n" + body)
        path.chmod(0o755)
        return path

    def routed_helper(self, name, body):
        return self.executable(
            name,
            'if [ "${PITHEAD_GO_HELPER:-}" = config-document ]; then '
            'exec "$MASKED_REAL_GO" "$@"; fi\n' + body,
        )

    def test_fixed_paths_match_bytes_and_scalar_truthiness(self):
        document = {
            "first": "雪",
            "dashboard": {"auth": {"password": "synthetic-password"}},
            "telegram": {"bot_token": ""},
            "workers": {"api_token": False},
            "monero": {"node_username": 0, "node_password": True, "view_key": None},
            "tari": {"view_key": {"synthetic": 1}},
            "p2pool": {"stratum_password": []},
            "healthchecks": {"ping_url": ["synthetic"]},
            "notifications": {"ntfy": {"url": {}, "token": "synthetic-token"}},
            "xvb": {"standby": {"source": "synthetic-source"}},
            "last": 9007199254740991,
        }
        result, work = self.compare("fixed", self.encoded(document))
        self.assertEqual(result[0], 0)
        raw = (work / "control/masked/config.json").read_bytes()
        masked = json.loads(raw)
        self.assertEqual(masked["telegram"]["bot_token"], "")
        self.assertFalse(masked["workers"]["api_token"])
        self.assertEqual(masked["monero"]["view_key"], None)
        for value in (
            masked["dashboard"]["auth"]["password"],
            masked["monero"]["node_username"],
            masked["monero"]["node_password"],
            masked["tari"]["view_key"],
            masked["p2pool"]["stratum_password"],
            masked["healthchecks"]["ping_url"],
            masked["notifications"]["ntfy"]["url"],
            masked["notifications"]["ntfy"]["token"],
            masked["xvb"]["standby"]["source"],
        ):
            self.assertEqual(value, SENTINEL)
        self.assertEqual(result[3][1][3], 0o644)
        self.assertIsNone(result[3][2])
        self.assertEqual(result[3][4], b"mkdir\nchmod:644\nmv\nworker-read\n")

    def test_worker_legacy_and_webhook_entries_match(self):
        document = {
            "workers": {
                "list": [
                    {"name": "a", "token": "synthetic-a", "api_token": 0},
                    {"name": "b", "token": "", "api_token": False},
                    {"name": "c"},
                ]
            },
            "dashboard": {
                "workers": [
                    {"token": ["synthetic"], "api_token": {}},
                    {"token": None},
                ]
            },
            "notifications": {"webhooks": ["synthetic-hook", "", False, 0, True, {}]},
        }
        _, work = self.compare("arrays", self.encoded(document))
        masked = json.loads((work / "control/masked/config.json").read_bytes())
        self.assertEqual(masked["workers"]["list"][0]["token"], SENTINEL)
        self.assertEqual(masked["workers"]["list"][0]["api_token"], SENTINEL)
        self.assertEqual(masked["workers"]["list"][1]["token"], "")
        self.assertFalse(masked["workers"]["list"][1]["api_token"])
        self.assertNotIn("token", masked["workers"]["list"][2])
        self.assertEqual(masked["dashboard"]["workers"][0]["token"], SENTINEL)
        self.assertEqual(masked["dashboard"]["workers"][0]["api_token"], SENTINEL)
        hooks = masked["notifications"]["webhooks"]
        self.assertEqual(hooks[0], {"__secret__": True, "slot": 0})
        self.assertEqual(hooks[1:3], ["", False])
        for slot in range(3, 6):
            self.assertEqual(hooks[slot], {"__secret__": True, "slot": slot})

    def test_unsupported_shapes_and_numbers_use_jq_fallback(self):
        log = self.directory / "helper.log"
        spy = self.routed_helper(
            "spy",
            'printf "%s\n" "${PITHEAD_GO_HELPER:-}" >>"$MASKED_HELPER_LOG"\n'
            'exec "$MASKED_REAL_GO" "$@"\n',
        )
        extra = {
            "MASKED_REAL_GO": str(GO_BINARY),
            "MASKED_HELPER_LOG": str(log),
        }
        for name, raw in (
            ("float", b'{"measurement":1.5,"dashboard":{"auth":{"password":"synthetic"}}}\n'),
            ("worker-scalar", b'{"workers":{"list":["synthetic"]}}\n'),
            ("root-array", b'[{"synthetic":true}]\n'),
        ):
            with self.subTest(name=name):
                result, _ = self.compare(name, raw, binary=spy, extra=extra)
                self.assertEqual(result[0], 0)
        self.assertEqual(log.read_text().splitlines(), ["config-masked"] * 3)

    def test_file_failures_callback_order_and_traps_match(self):
        raw = b'{"dashboard":{"auth":{"password":"synthetic"}}}\n'

        def stale(work):
            masked = work / "control/masked"
            masked.mkdir(parents=True)
            (masked / "config.json").write_bytes(b'{"old":true}\n')
            (masked / "worker-read-tokens.json").write_bytes(b"old\n")

        cases = (
            ("worker", {"CONFIG_MASKED_WORKER_RC": "7"}, None),
            ("chmod", {"CONFIG_MASKED_FAIL_TOOL": "chmod"}, None),
            ("mv", {"CONFIG_MASKED_FAIL_TOOL": "mv"}, stale),
            ("mkdir", {"CONFIG_MASKED_FAIL_TOOL": "mkdir"}, None),
            ("jq", {"CONFIG_MASKED_FAIL_TOOL": "jq"}, None),
        )
        for name, extra, prepare in cases:
            with self.subTest(name=name):
                input_raw = b'{"measurement":1.5}\n' if name == "jq" else raw
                self.compare(name, input_raw, extra=extra, prepare=prepare)
        result, _ = self.compare("invalid", b'{"broken":\n', extra={"CONFIG_MASKED_ERR_TRAP": "1"})
        self.assertEqual(result[0], 1)
        self.assertIn(b"err:1\n", result[3][4])

    def test_helper_and_input_producer_failures_fall_back_cleanly(self):
        raw = b'{"dashboard":{"auth":{"password":"synthetic"}}}\n'
        common = {"MASKED_REAL_GO": str(GO_BINARY)}
        for name, body in (
            ("refused", "exit 125\n"),
            ("empty", "exit 0\n"),
            ("truncated", "printf '{\"poison\":true}'; exit 0\n"),
            ("trailing", "printf '{\"poison\":true}\\0extra'; exit 0\n"),
            ("failed", "printf '{\"poison\":true}\\0'; exit 42\n"),
        ):
            with self.subTest(name=name):
                fake = self.routed_helper(name, body)
                _, work = self.compare(name, raw, binary=fake, extra=common)
                self.assertNotIn(b"poison", (work / "control/masked/config.json").read_bytes())
        self.compare("missing", raw, binary=self.directory / "missing")
        self.compare("producer", raw, extra={"CONFIG_MASKED_FAIL_TOOL": "cat"})

    def test_supported_render_does_not_invoke_jq(self):
        forbidden = self.directory / "forbidden"
        forbidden.mkdir()
        marker = self.directory / "jq-called"
        jq = forbidden / "jq"
        jq.write_text('#!/bin/sh\nprintf "called\\n" >>"$MASKED_JQ_LOG"\nexit 91\n')
        jq.chmod(0o755)
        work = self.work("native-no-jq", b'{"dashboard":{"auth":{"password":"synthetic"}}}\n')
        result = self.invoke(
            "go",
            work,
            extra={
                "MASKED_JQ_LOG": str(marker),
                "PATH": str(forbidden) + os.pathsep + os.environ.get("PATH", os.defpath),
            },
        )
        self.assertEqual(result[0], 0)
        self.assertEqual(
            json.loads((work / "control/masked/config.json").read_bytes())["dashboard"]["auth"][
                "password"
            ],
            SENTINEL,
        )
        self.assertFalse(marker.exists())

    def test_source_only_callers_use_silent_jq_fallback(self):
        raw = b'{"dashboard":{"auth":{"password":"synthetic"}}}\n'
        result, work = self.compare("source-only", raw, extra={"CONFIG_MASKED_SOURCE_ONLY": "1"})
        self.assertEqual(result[:3], (0, b"", b""))
        masked = json.loads((work / "control/masked/config.json").read_bytes())
        self.assertEqual(masked["dashboard"]["auth"]["password"], SENTINEL)

    def test_private_helper_runtime_paths_and_protocol(self):
        raw = b'{"custom":{"key":"synthetic"}}'
        completed = self.helper(raw, [["custom", "key"]])
        self.assertEqual((completed.returncode, completed.stderr), (0, b""))
        self.assertTrue(completed.stdout.endswith(b"\0"))
        self.assertEqual(json.loads(completed.stdout[:-1])["custom"]["key"], SENTINEL)
        good = raw + b'\0[["custom","key"]]\0' + b"0\0"
        env = {key: value for key, value in os.environ.items() if not key.startswith("PITHEAD_")}
        env["PITHEAD_GO_HELPER"] = "config-masked"
        bad = (
            good[:-1],
            good + b"extra",
            raw + b'\0[["custom","key"]]\0' + b"1\0",
            raw + b"\0bad\0" + b"0\0",
            raw + b"\0[[]]\0" + b"0\0",
            raw + b"\0[[1]]\0" + b"0\0",
            b'{"measurement":1.5}\0[]\0' + b"0\0",
        )
        results = [
            subprocess.run(  # noqa: S603
                [str(GO_BINARY)],
                env=env,
                input=payload,
                capture_output=True,
                check=False,
                timeout=15,
            )
            for payload in bad
        ]
        results.append(self.helper(raw, [["custom", "key"]], args=("extra",)))
        for result in results:
            self.assertEqual((result.returncode, result.stdout, result.stderr), (125, b"", b""))

    def test_same_inode_temp_uses_jq_without_native_writer(self):
        raw = b'{"dashboard":{"auth":{"password":"synthetic"}}}\n'
        for kind in ("hardlink", "symlink"):
            log = self.directory / f"{kind}.log"
            spy = self.routed_helper(
                f"{kind}-spy",
                'printf "%s\n" "${PITHEAD_GO_HELPER:-}" >>"$MASKED_HELPER_LOG"\n'
                'exec "$MASKED_REAL_GO" "$@"\n',
            )

            def alias(work, link_kind=kind):
                masked = work / "control/masked"
                masked.mkdir(parents=True)
                target = masked / ".config.json.tmp"
                if link_kind == "hardlink":
                    os.link(work / "config.json", target)
                else:
                    target.symlink_to("../../config.json")

            with self.subTest(kind=kind):
                result, _ = self.compare(
                    "alias-" + kind,
                    raw,
                    binary=spy,
                    extra={"MASKED_REAL_GO": str(GO_BINARY), "MASKED_HELPER_LOG": str(log)},
                    prepare=alias,
                )
                self.assertEqual(result[3][0][1], 0)
                if log.exists():
                    self.assertNotIn("config-masked", log.read_text().splitlines())


if __name__ == "__main__":
    unittest.main(verbosity=2)
