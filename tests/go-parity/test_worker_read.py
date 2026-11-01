import hashlib
import hmac
import json
import os
import shutil
import stat
import subprocess
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
ADAPTER = ROOT / "tests/go-parity/worker_read_reference.sh"
GO_BINARY = ROOT / "go/bin/pithead"
BASH = shutil.which("bash")
if BASH is None:
    raise RuntimeError("bash is required")


class WorkerReadParityTests(unittest.TestCase):
    def setUp(self):
        cache = ROOT / ".go-cache"
        cache.mkdir(exist_ok=True)
        self.scratch = tempfile.TemporaryDirectory(dir=cache)
        self.addCleanup(self.scratch.cleanup)
        self.directory = Path(self.scratch.name)

    def work(self, name, raw):
        path = self.directory / name
        path.mkdir()
        (path / "config.json").write_bytes(raw)
        return path

    def env(self, implementation, binary=None, extra=None):
        env = {key: value for key, value in os.environ.items() if not key.startswith("PITHEAD_")}
        env.pop("BASH_ENV", None)
        env.update(
            WORKER_READ_PARITY_IMPL=implementation,
            PITHEAD_GO_BINARY=str(binary or GO_BINARY),
            NO_COLOR="1",
        )
        env.update(extra or {})
        return env

    def invoke(self, implementation, work, *, binary=None, extra=None):
        result = subprocess.run(  # noqa: S603
            [BASH, str(ADAPTER), str(ROOT), str(work), "render"],
            env=self.env(implementation, binary, extra),
            capture_output=True,
            check=False,
            timeout=15,
        )
        return result.returncode, result.stdout, result.stderr, self.state(work)

    def state(self, work):
        def entry(path):
            if not path.exists():
                return None
            return path.read_bytes(), stat.S_IMODE(path.stat().st_mode)

        masked = work / "masked"
        leftovers = []
        if masked.exists():
            for path in sorted(masked.glob(".worker-read-*")):
                kind = "rows" if path.name.startswith(".worker-read-rows.") else "tokens"
                leftovers.append((kind, entry(path)))
        logs = tuple(
            (work / name).read_bytes() if (work / name).exists() else None
            for name in ("owner.log", "hmac-called", "openssl-failed")
        )
        return (
            entry(work / "config.json"),
            entry(masked / "worker-read-tokens.json"),
            leftovers,
            logs,
        )

    def compare(self, name, document, *, extra=None, binary=None, prepare=None):
        raw = json.dumps(document, ensure_ascii=False, separators=(",", ":")).encode() + b"\n"
        baseline = self.work(name + "-bash", raw)
        selected = self.work(name + "-go", raw)
        if prepare:
            prepare(baseline)
            prepare(selected)
        expected = self.invoke("bash", baseline, extra=extra)
        actual = self.invoke("go", selected, binary=binary, extra=extra)
        self.assertEqual(actual, expected)
        return actual

    def worker(self, name="rig1", token="0123456789abcdef" * 2, **fields):
        return {"name": name, "host": "rig.example", "token": token, **fields}

    def document(self, workers, **fields):
        return {"workers": {"list": workers, **fields}}

    def executable(self, name, body):
        path = self.directory / name
        path.write_text("#!/usr/bin/env bash\nset -eu\n" + body)
        path.chmod(0o755)
        return path

    def helper(self, operation, fields):
        payload = b"\0".join(fields) + b"\0"
        env = {key: value for key, value in os.environ.items() if not key.startswith("PITHEAD_")}
        env["PITHEAD_GO_HELPER"] = "config-worker-read"
        return subprocess.run(  # noqa: S603
            [str(GO_BINARY), operation],
            env=env,
            input=payload,
            capture_output=True,
            check=False,
            timeout=15,
        )

    def test_output_bytes_mode_order_duplicates_and_ports(self):
        workers = [
            self.worker("same", port="08081"),
            self.worker("same", token="abcdef0123456789" * 2),
        ]
        result = self.compare("ordinary", self.document(workers, api_port="08080"))
        self.assertEqual(result[:3], (0, b"", b""))
        final = result[3][1]
        self.assertIsNotNone(final)
        self.assertEqual(final[1], 0o600)
        records = json.loads(final[0])
        self.assertEqual([record["name"] for record in records], ["same", "same"])
        self.assertEqual([record["port"] for record in records], [8081, 8080])
        self.assertEqual(list(records[0]), ["name", "host", "port", "read_token"])
        self.assertEqual(result[3][2], [])

    def test_descriptor_filtering_matches(self):
        workers = [
            self.worker("missing-token", token=None),
            self.worker("numeric-token", token=17),
            self.worker(""),
            {"name": "missing-host", "token": "x" * 32},
            self.worker("zero", port=0),
            self.worker("large", port=65536),
            self.worker("text", port="abc"),
            self.worker("valid", port=65535),
        ]
        result = self.compare("filter", self.document(workers))
        records = json.loads(result[3][1][0])
        self.assertEqual([(row["name"], row["port"]) for row in records], [("valid", 65535)])

    def test_weak_and_non_ascii_tokens_warn_and_drop(self):
        workers = [
            self.worker("short", token="x" * 31),
            self.worker("space", token="x" * 31 + " "),
            self.worker("unicode", token="é" * 32),
        ]
        result = self.compare("warnings", self.document(workers))
        self.assertEqual(json.loads(result[3][1][0]), [])
        self.assertIn(b"warn:RigForge worker 'short'", result[2])
        self.assertIn(b"warn:RigForge worker 'unicode'", result[2])
        self.assertEqual(result[2].count(b"32+ printable ASCII"), 3)

    def test_control_characters_preserve_legacy_line_transport(self):
        cases = (
            ("embedded", "embedded\nline", "host\nline"),
            ("trailing", "trailing\n", "host\n"),
            ("carriage", "carriage\rreturn", "host\rreturn"),
            ("nul", "nul\u0000name", "nul\u0000host"),
        )
        for case, name, host in cases:
            with self.subTest(case=case):
                result = self.compare(
                    "control-" + case, self.document([self.worker(name, host=host)])
                )
                if result[0] != 0:
                    self.assertIsNone(result[3][1])
                    self.assertEqual(result[3][2], [])

    def test_literal_backslash_and_long_key_hmac_vectors(self):
        tokens = ["0123456789abcdef\\0123456789abcdef", "x" * 65]
        result = self.compare(
            "hmac", self.document([self.worker("slash", tokens[0]), self.worker("long", tokens[1])])
        )
        records = json.loads(result[3][1][0])
        expected = [
            hmac.new(token.encode(), b"rigforge:api-read:v1", hashlib.sha256).hexdigest()
            for token in tokens
        ]
        self.assertEqual([row["read_token"] for row in records], expected)
        self.assertEqual(
            expected[0], "cce295e5a24453987365f2392bea539dd26e25d404c8742569b4f7b7a015c00e"
        )

    def test_hmac_and_openssl_failures_fire_and_clean_up(self):
        def stale(work):
            masked = work / "masked"
            masked.mkdir()
            target = masked / "worker-read-tokens.json"
            target.write_bytes(b"stale\n")
            target.chmod(0o644)

        cases = (
            ("hmac", self.worker(), {"WORKER_READ_HMAC_FAIL": "1"}, 1),
            ("openssl", self.worker(token="x" * 65), {"WORKER_READ_OPENSSL_FAIL": "1"}, 2),
        )
        for name, worker, extra, marker in cases:
            with self.subTest(name=name):
                result = self.compare(
                    name + "-failure", self.document([worker]), extra=extra, prepare=stale
                )
                self.assertNotEqual(result[0], 0)
                self.assertIsNone(result[3][1])
                self.assertEqual(result[3][2], [])
                self.assertEqual(result[3][3][marker], b"")

    def test_mktemp_chmod_and_move_failures_clean_up(self):
        for failure in ("mktemp-1", "mktemp-2", "chmod-1", "chmod-2", "mv"):
            with self.subTest(failure=failure):
                result = self.compare(
                    "failure-" + failure,
                    self.document([self.worker()]),
                    extra={"WORKER_READ_FAIL_TOOL": failure},
                )
                self.assertNotEqual(result[0], 0)
                self.assertIsNone(result[3][1])
                self.assertEqual(result[3][2], [])

    def test_ownership_fallback_and_failure_match(self):
        fallback = self.compare(
            "owner-fallback",
            self.document([self.worker()]),
            extra={"WORKER_READ_OWNER": "fallback"},
        )
        self.assertEqual(fallback[0], 0)
        self.assertEqual(fallback[3][3][0].count(b"chown:1000:1000"), 1)
        self.assertIn(b"sudo:chown 1000:1000", fallback[3][3][0])
        failure = self.compare(
            "owner-failure", self.document([self.worker()]), extra={"WORKER_READ_OWNER": "fail"}
        )
        self.assertEqual(failure[0], 1)
        self.assertIsNone(failure[3][1])

    def test_refused_malformed_partial_and_producer_failure_fall_back(self):
        bodies = {
            "refused": 'printf "%s:%s\\n" "$PITHEAD_GO_HELPER" "${1:-}" >>helper.log\nexit 125\n',
            "malformed": 'printf "%s:%s\\n" "$PITHEAD_GO_HELPER" "${1:-}" >>helper.log\nprintf bad\n',
            "partial": 'printf "%s:%s\\n" "$PITHEAD_GO_HELPER" "${1:-}" >>helper.log\nprintf "partial\\0"\nexit 9\n',
        }
        for name, body in bodies.items():
            with self.subTest(name=name):
                helper = self.executable("helper-" + name, body)
                result = self.compare(
                    "helper-" + name, self.document([self.worker()]), binary=helper
                )
                self.assertEqual(result[0], 0)
                calls = (self.directory / ("helper-" + name + "-go") / "helper.log").read_text()
                self.assertIn("config-worker-read:project", calls)
        result = self.compare(
            "producer-failure",
            self.document([self.worker()]),
            extra={"WORKER_READ_FAIL_TOOL": "cat"},
        )
        self.assertEqual(result[0], 0)

    def test_partial_values_frame_cannot_reuse_previous_worker(self):
        helper = self.executable(
            "values-partial",
            'if [ "${1:-}" = values ]; then\n'
            '  if [ -e .values-seen ]; then printf "stale\\0host\\0"; exit 0; fi\n'
            "  : >.values-seen\n"
            "fi\n"
            'exec "$WORKER_READ_REAL_GO" "$@"\n',
        )
        workers = [
            self.worker("first", host="first.example"),
            self.worker("second", token="abcdef0123456789" * 2, host="second.example"),
        ]
        result = self.compare(
            "values-partial",
            self.document(workers),
            binary=helper,
            extra={"WORKER_READ_REAL_GO": str(GO_BINARY)},
        )
        records = json.loads(result[3][1][0])
        self.assertEqual(
            [(record["name"], record["host"]) for record in records],
            [("first", "first.example"), ("second", "second.example")],
        )

    def test_native_path_needs_no_jq_and_source_only_falls_back(self):
        result = self.compare(
            "source-only",
            self.document([self.worker()]),
            extra={"WORKER_READ_SOURCE_ONLY": "1"},
        )
        self.assertEqual(result[0], 0)
        work = self.work("native-no-jq", json.dumps(self.document([self.worker()])).encode())
        native = self.invoke("go", work, extra={"WORKER_READ_FAIL_TOOL": "jq"})
        self.assertEqual(native[:3], (0, b"", b""))
        self.assertIsNotNone(native[3][1])

    def test_same_inode_project_and_slurp_targets_use_reference_path(self):
        def project_alias(work):
            masked = work / "masked"
            masked.mkdir()
            os.link(work / "config.json", masked / ".alias-rows")

        def slurp_alias(work):
            masked = work / "masked"
            masked.mkdir()
            rows = masked / ".alias-rows"
            rows.write_bytes(b"")
            os.link(rows, masked / ".alias-tmp")

        spy = self.executable(
            "alias-spy",
            'printf "%s\\n" "${1:-}" >>helper.log\nexec "$WORKER_READ_REAL_GO" "$@"\n',
        )
        for name, prepare in (("project", project_alias), ("slurp", slurp_alias)):
            with self.subTest(name=name):
                result = self.compare(
                    "alias-" + name,
                    self.document([self.worker()]),
                    binary=spy,
                    extra={"WORKER_READ_ALIAS": name, "WORKER_READ_REAL_GO": str(GO_BINARY)},
                    prepare=prepare,
                )
                self.assertEqual(result[0], 0)
                calls = (self.directory / ("alias-" + name + "-go") / "helper.log").read_text()
                self.assertNotIn(name, calls.splitlines())

    def test_helper_protocol_success_and_refusals(self):
        raw = json.dumps(self.document([self.worker(port="08081")]), separators=(",", ":")).encode()
        project = self.helper("project", (raw, b"0"))
        self.assertEqual((project.returncode, project.stderr), (0, b""))
        rows = project.stdout[:-1]
        self.assertTrue(project.stdout.endswith(b"\0"))
        values = self.helper("values", (rows.rstrip(b"\n"), b"0"))
        self.assertEqual(
            values.stdout,
            b"\0".join((b"rig1", b"rig.example", b"0123456789abcdef0123456789abcdef", b"08081"))
            + b"\0",
        )
        record = self.helper("record", (b"rig1", b"rig.example", b"08081", b"read", b"0"))
        self.assertEqual(
            json.loads(record.stdout[:-1]),
            {"name": "rig1", "host": "rig.example", "port": 8081, "read_token": "read"},
        )
        slurp = self.helper("slurp", (record.stdout[:-1] + b"\n", b"0"))
        self.assertEqual(json.loads(slurp.stdout[:-1]), [json.loads(record.stdout[:-1])])
        good = raw + b"\0" + b"0\0"
        bad_payloads = (
            good[:-1],
            good + b"extra",
            raw + b"\0" + b"7\0",
            raw + b"\0" + b"00\0",
            b"{bad\0" + b"0\0",
        )
        helper_env = {
            key: value for key, value in os.environ.items() if not key.startswith("PITHEAD_")
        }
        helper_env["PITHEAD_GO_HELPER"] = "config-worker-read"
        bad = (
            subprocess.run(  # noqa: S603
                [str(GO_BINARY), "project"],
                env=helper_env,
                input=payload,
                capture_output=True,
                check=False,
                timeout=15,
            )
            for payload in bad_payloads
        )
        for result in bad:
            self.assertEqual((result.returncode, result.stdout, result.stderr), (125, b"", b""))
        refused = (
            self.helper("values", (b"{bad", b"0")),
            self.helper("values", (rows.rstrip(b"\n"), b"9")),
            self.helper("record", (b"line\nbreak", b"host", b"8080", b"read", b"0")),
            self.helper("record", (b"name", b"host\rreturn", b"8080", b"read", b"0")),
            self.helper("record", (b"name", b"host", b"0", b"read", b"0")),
            self.helper("slurp", (b"{bad", b"0")),
            self.helper("slurp", (record.stdout[:-1], b"3")),
        )
        for result in refused:
            self.assertEqual((result.returncode, result.stdout, result.stderr), (125, b"", b""))


if __name__ == "__main__":
    unittest.main(verbosity=2)
