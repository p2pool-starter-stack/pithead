import hashlib
import json
import os
import shutil
import subprocess
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
ADAPTER = ROOT / "tests/go-parity/dashboard_auth_reference.sh"
GO_BINARY = ROOT / "go/bin/pithead"
BASH = shutil.which("bash")
if BASH is None:
    raise RuntimeError("bash is required")

SEEDS = (
    "seed-user",
    "seed-hash",
    "seed-fingerprint",
    "seed-onion",
    "seed-client-auth",
    "seed-control",
)
SYNTHETIC_HASH = "c3ludGhldGljLWhhc2g="


class DashboardAuthParityTests(unittest.TestCase):
    def setUp(self):
        self.scratch = tempfile.TemporaryDirectory()
        self.addCleanup(self.scratch.cleanup)
        self.directory = Path(self.scratch.name)
        self.config = self.directory / "config.json"
        self.calls = self.directory / "calls"
        self.marker = self.directory / "jq-called"
        self.tools = self.directory / "bin"
        self.tools.mkdir()
        jq = self.tools / "jq"
        jq.write_text('#!/bin/sh\nprintf called >"$JQ_MARKER"\nexit 91\n')
        jq.chmod(0o755)

    def environment(self, implementation, binary=None, forbid_jq=False, extra=None):
        env = {key: value for key, value in os.environ.items() if not key.startswith("PITHEAD_")}
        env.pop("BASH_ENV", None)
        env.update(
            DASHBOARD_AUTH_PARITY_IMPL=implementation,
            DASHBOARD_AUTH_CALL_LOG=str(self.calls),
            PITHEAD_GO_BINARY=str(binary or GO_BINARY),
            JQ_MARKER=str(self.marker),
        )
        if forbid_jq:
            env["PATH"] = str(self.tools) + os.pathsep + env.get("PATH", os.defpath)
        env.update(extra or {})
        return env

    def invoke(self, implementation, raw, *, binary=None, forbid_jq=False, extra=None):
        self.config.write_bytes(raw)
        self.calls.write_bytes(b"")
        self.marker.unlink(missing_ok=True)
        completed = subprocess.run(  # noqa: S603
            [BASH, str(ADAPTER), str(ROOT), str(self.config)],
            env=self.environment(implementation, binary, forbid_jq, extra),
            capture_output=True,
            check=False,
            timeout=15,
        )
        return completed, self.calls.read_bytes()

    def helper(self, operation, fields, binary=None):
        env = self.environment("go", binary=binary)
        env["PITHEAD_GO_HELPER"] = "config-dashboard-auth"
        payload = b"\0".join(fields) + b"\0"
        return subprocess.run(  # noqa: S603
            [str(binary or GO_BINARY), operation],
            env=env,
            input=payload,
            capture_output=True,
            check=False,
            timeout=15,
        )

    def encoded(self, document):
        return json.dumps(document, ensure_ascii=False, separators=(",", ":")).encode()

    def result(self, completed):
        return completed.returncode, completed.stdout, completed.stderr

    def state(self, completed):
        values = completed.stdout.split(b"\0")
        self.assertEqual(len(values), 8)
        self.assertEqual((values[0], values[-1]), (b"", b""))
        return tuple(value.decode() for value in values[1:-1])

    def compare(self, raw, *, native=False, binary=None, extra=None):
        baseline, baseline_calls = self.invoke("bash", raw, extra=extra)
        selected, selected_calls = self.invoke(
            "go", raw, binary=binary, forbid_jq=native, extra=extra
        )
        self.assertEqual(self.result(selected), self.result(baseline))
        self.assertEqual(selected_calls, baseline_calls)
        if native:
            self.assertFalse(self.marker.exists())
        return selected, selected_calls

    def test_supported_auth_and_policy_match_without_jq(self):
        cases = [
            ({}, {}, ("admin", "", "", "false", "false", "false"), b""),
            (
                {"dashboard": {"auth": {"username": "operator", "password": "safe-passphrase"}}},
                {},
                (
                    "operator",
                    SYNTHETIC_HASH,
                    hashlib.sha256(b"safe-passphrase").hexdigest(),
                    "false",
                    "false",
                    "false",
                ),
                b"hash:",
            ),
            (
                {
                    "dashboard": {
                        "auth": {"username": "admin", "password": "correct horse battery"},
                        "onion": {"enabled": True},
                        "control": {"enabled": True},
                    }
                },
                {},
                (
                    "admin",
                    SYNTHETIC_HASH,
                    hashlib.sha256(b"correct horse battery").hexdigest(),
                    "true",
                    "true",
                    "true",
                ),
                b"hash:",
            ),
        ]
        credential = "unchanged-password"
        fingerprint = hashlib.sha256(credential.encode()).hexdigest()
        cases.append(
            (
                {"dashboard": {"auth": {"username": "cached", "password": credential}}},
                {
                    "DASHBOARD_AUTH_PREVIOUS_FP": fingerprint,
                    "DASHBOARD_AUTH_PREVIOUS_HASH": "cached-hash",
                },
                ("cached", "cached-hash", fingerprint, "false", "false", "false"),
                b"env_get:",
            )
        )
        for document, extra, expected, call in cases:
            with self.subTest(document=document):
                completed, calls = self.compare(self.encoded(document), native=True, extra=extra)
                self.assertEqual(completed.returncode, 0)
                self.assertEqual(self.state(completed), expected)
                self.assertIn(call, calls)
                self.assertNotIn(
                    document.get("dashboard", {}).get("auth", {}).get("password", "x").encode(),
                    calls,
                )

    def test_auth_errors_precede_hashing_and_preserve_partial_state(self):
        cases = [
            (
                {"dashboard": {"auth": {"username": "bad user", "password": "valid-password"}}},
                ("bad user", "", "", *SEEDS[3:]),
                b"dashboard.auth.username",
            ),
            (
                {"dashboard": {"auth": {"username": "admin", "password": "short"}}},
                ("admin", "", "", *SEEDS[3:]),
                b"dashboard.auth.password must be 8",
            ),
        ]
        for document, expected, message in cases:
            with self.subTest(document=document):
                completed, calls = self.compare(self.encoded(document), native=True)
                self.assertEqual(completed.returncode, 1)
                self.assertEqual(self.state(completed), expected)
                self.assertIn(message, completed.stderr)
                self.assertEqual(calls, b"")

    def test_hash_and_policy_failures_keep_reference_order(self):
        valid = {"username": "admin", "password": "correct horse battery"}
        cases = [
            (
                {"dashboard": {"auth": valid}},
                {"DASHBOARD_AUTH_HASH_RC": "1"},
                b"Could not hash dashboard.auth.password",
                b"hash:",
            ),
            (
                {
                    "dashboard": {
                        "auth": valid,
                        "onion": {"enabled": True, "client_auth": False},
                        "control": {"enabled": True},
                    }
                },
                {},
                b"dashboard.control.enabled is true on a published onion",
                b"hash:",
            ),
            (
                {
                    "dashboard": {
                        "auth": {"username": "admin", "password": "passwordpassword"},
                        "onion": {"enabled": True},
                    }
                },
                {},
                b"well-known weak pattern",
                b"hash:",
            ),
        ]
        for document, extra, message, first_call in cases:
            with self.subTest(document=document):
                completed, calls = self.compare(self.encoded(document), native=True, extra=extra)
                self.assertEqual(completed.returncode, 1)
                self.assertIn(message, completed.stderr)
                self.assertTrue(calls.startswith(b"env_get:"))
                self.assertIn(first_call, calls)
                self.assertNotIn(document["dashboard"]["auth"]["password"].encode(), calls)

    def test_plain_http_warning_happens_after_hash_before_policy(self):
        raw = self.encoded(
            {"dashboard": {"auth": {"username": "admin", "password": "safe-passphrase"}}}
        )
        completed, calls = self.compare(raw, extra={"DASHBOARD_AUTH_SECURE": "false"})
        self.assertEqual(completed.returncode, 0)
        self.assertIn(b"credentials would travel over plain HTTP", completed.stderr)
        lines = calls.splitlines()
        self.assertTrue(lines[0].startswith(b"env_get:"))
        self.assertTrue(lines[2].startswith(b"hash:"))
        self.assertTrue(lines[3].startswith(b"warn:"))
        self.assertTrue(lines[3].endswith(b":seed-onion:seed-client-auth:seed-control"))
        for enabled, expected_warning in ((True, False), ("YES", True)):
            document = {
                "dashboard": {
                    "auth": {"password": "correct horse battery"},
                    "onion": {"enabled": enabled},
                }
            }
            completed, calls = self.compare(
                self.encoded(document), extra={"DASHBOARD_AUTH_SECURE": "false"}
            )
            self.assertEqual(completed.returncode, 0)
            self.assertEqual(b"warn:" in calls, expected_warning)

    def test_unsupported_documents_and_bad_helpers_fall_back(self):
        documents = [
            b'{"dashboard":{"auth":{"password":"unicode-\xc3\xa9-pass"}}}',
            b'{"dashboard":{"auth":{"username":"op\xc3\xa9rator","password":"valid-password"}}}',
            b'{"dashboard":{"auth":{"password":"one"},"auth":{"password":"two"}}}',
            b'{"dashboard":',
        ]
        for raw in documents:
            with self.subTest(raw=raw):
                self.compare(raw)
        fake = self.directory / "fake-helper"
        fake.write_text(
            '#!/bin/sh\ncase "$1" in\n'
            'settings) printf "admin\\0\\0\\0extra\\0" ;;\n'
            'policy) printf "9\\0false\\0false\\0false\\0\\0extra\\0" ;;\n'
            "esac\n"
        )
        fake.chmod(0o755)
        self.compare(self.encoded({}), binary=fake)
        fake.write_text("#!/bin/sh\nexit 125\n")
        self.compare(self.encoded({}), binary=fake)
        completed, _ = self.compare(self.encoded({}), extra={"DASHBOARD_AUTH_WITHOUT_GO_HOOK": "1"})
        self.assertEqual(completed.returncode, 0)

    def test_private_helpers_reject_bad_frames(self):
        raw = self.encoded({"dashboard": {"auth": {"username": "admin", "password": "password1"}}})
        settings = self.helper("settings", (raw, b"0"))
        self.assertEqual(settings.returncode, 0)
        self.assertEqual(settings.stdout.split(b"\0"), [b"admin", b"password1", b"", b""])
        policy = self.helper("policy", (raw, b"password1", b"pithead", b"0"))
        self.assertEqual(policy.returncode, 0)
        self.assertEqual(policy.stdout.split(b"\0"), [b"3", b"false", b"false", b"false", b"", b""])
        for name, fields in [
            ("settings", (raw, b"9")),
            ("policy", (raw, b"password1", b"pithead", b"9")),
        ]:
            with self.subTest(name=name):
                rejected = self.helper(name, fields)
                self.assertEqual(
                    (rejected.returncode, rejected.stdout, rejected.stderr), (125, b"", b"")
                )

    def test_auth_boundaries_and_policy_verdicts_match_without_jq(self):
        cases = [
            ("", "", {}, 0, False),
            ("bad user", "", {}, 0, False),
            ("u" * 64, "eight888", {}, 0, True),
            ("u" * 65, "eight888", {}, 1, False),
            ("admin", "a" * 7, {}, 1, False),
            ("admin", "a" * 8, {}, 0, True),
            ("admin", "a" * 128, {}, 0, True),
            ("admin", "a" * 129, {}, 1, False),
            ("admin", 'abcdefg"', {}, 1, False),
            ("admin", "", {"onion": {"enabled": True}}, 1, False),
            ("admin", "", {"control": {"enabled": True}}, 1, False),
            ("admin", "short-password", {"onion": {"enabled": True}}, 1, True),
            ("admin", "red-blue-green-x", {"onion": {"enabled": True}}, 0, True),
            ("admin", "A" * 16, {"onion": {"enabled": True}}, 1, True),
            ("admin", "A" * 16, {"onion": {"enabled": True}, "control": {"enabled": []}}, 1, True),
            ("admin", "valid-password", {"onion": {"enabled": False, "client_auth": []}}, 0, True),
            (
                "admin",
                "red-blue-green-x",
                {"onion": {"enabled": True, "client_auth": False}, "control": {"enabled": True}},
                1,
                True,
            ),
        ]
        for pattern in ("PASSWORDPASSWORD", "0123456789", "QWERTYUIOP", "CHANGEME", "LETMEIN"):
            cases.append(
                ("admin", f"prefix-{pattern}-suffix", {"onion": {"enabled": True}}, 1, True)
            )
        for enabled in (True, "YES", "on", 1):
            cases.append(("admin", "red-blue-green-x", {"onion": {"enabled": enabled}}, 0, True))
            cases.append(("admin", "valid-password", {"control": {"enabled": enabled}}, 0, True))
        for client in (False, "false", "OFF", 0, None):
            cases.append(
                (
                    "admin",
                    "red-blue-green-x",
                    {"onion": {"enabled": True, "client_auth": client}},
                    0,
                    True,
                )
            )
        for user, password, policy, expected_status, hashes in cases:
            with self.subTest(user=user, password_length=len(password), policy=policy):
                document = {
                    "dashboard": {"auth": {"username": user, "password": password}, **policy}
                }
                completed, calls = self.compare(self.encoded(document), native=True)
                self.assertEqual(completed.returncode, expected_status)
                self.assertEqual(calls.count(b"hash:"), int(hashes))
                if password:
                    self.assertNotIn(password.encode(), calls)


if __name__ == "__main__":
    unittest.main()
