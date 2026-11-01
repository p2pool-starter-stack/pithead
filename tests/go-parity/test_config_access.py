import json
import os
import shutil
import subprocess
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
ADAPTER = ROOT / "tests/go-parity/config_access_reference.sh"
GO_BINARY = ROOT / "go/bin/pithead"
BASH = shutil.which("bash")
if BASH is None:
    raise RuntimeError("bash is required")


class ConfigAccessParityTests(unittest.TestCase):
    def setUp(self):
        cache = ROOT / ".go-cache"
        cache.mkdir(exist_ok=True)
        self.scratch = tempfile.TemporaryDirectory(dir=cache)
        self.addCleanup(self.scratch.cleanup)
        self.directory = Path(self.scratch.name)
        self.config = self.directory / "config.json"
        self.calls = self.directory / "calls"
        self.traps = self.directory / "traps"
        self.marker = self.directory / "jq-called"
        self.queries = self.directory / "jq-queries"
        self.bin = self.directory / "bin"
        self.bin.mkdir()
        jq = self.bin / "jq"
        jq.write_text(
            '#!/bin/sh\nprintf "%s\\n" "$*" >>"$CONFIG_ACCESS_JQ_QUERIES"\n'
            'if [ "$1" = -r ] && [ "$2" = \'.monero.node_username // empty\' ]; then\n'
            '    printf "%s\\n" "${CONFIG_ACCESS_USERNAME_FACT:-}"\n'
            '    exit "${CONFIG_ACCESS_USERNAME_RC:-0}"\nfi\n'
            'printf called >"$CONFIG_ACCESS_JQ_MARKER"\nexit 91\n'
        )
        jq.chmod(0o755)

    def environment(self, implementation, *, binary=None, native=False, extra=None):
        env = {key: value for key, value in os.environ.items() if not key.startswith("PITHEAD_")}
        env.pop("BASH_ENV", None)
        env.update(
            CONFIG_ACCESS_PARITY_IMPL=implementation,
            CONFIG_ACCESS_CALL_LOG=str(self.calls),
            CONFIG_ACCESS_TRAP_LOG=str(self.traps),
            CONFIG_ACCESS_JQ_MARKER=str(self.marker),
            CONFIG_ACCESS_JQ_QUERIES=str(self.queries),
            PITHEAD_GO_BINARY=str(binary or GO_BINARY),
        )
        if native:
            env["PATH"] = str(self.bin) + os.pathsep + env.get("PATH", os.defpath)
        env.update(extra or {})
        return env

    def invoke(
        self,
        operation,
        implementation,
        raw,
        *,
        binary=None,
        native=False,
        extra=None,
        shell=BASH,
    ):
        self.config.write_bytes(raw)
        self.calls.write_bytes(b"")
        self.traps.write_bytes(b"")
        self.queries.write_bytes(b"")
        self.marker.unlink(missing_ok=True)
        completed = subprocess.run(  # noqa: S603
            [shell, str(ADAPTER), str(ROOT), operation, str(self.config)],
            env=self.environment(implementation, binary=binary, native=native, extra=extra),
            capture_output=True,
            check=False,
            timeout=15,
        )
        return completed, self.calls.read_bytes(), self.traps.read_bytes()

    def compare(
        self,
        operation,
        document,
        *,
        native=True,
        extra=None,
        binary=None,
        shell=BASH,
        compare_calls=True,
    ):
        raw = document if isinstance(document, bytes) else self.encoded(document)
        selected_extra = dict(extra or {})
        if operation == "node" and native and "CONFIG_ACCESS_USERNAME_FACT" not in selected_extra:
            selected_extra["CONFIG_ACCESS_USERNAME_FACT"] = self.username_fact(document)
        baseline = self.invoke(operation, "bash", raw, extra=extra, shell=shell)
        selected = self.invoke(
            operation,
            "go",
            raw,
            binary=binary,
            native=native,
            extra=selected_extra,
            shell=shell,
        )
        self.assertEqual(self.result(selected[0]), self.result(baseline[0]))
        if compare_calls:
            self.assertEqual(selected[1:], baseline[1:])
        else:
            self.assertEqual(selected[2], baseline[2])
        if native:
            self.assertFalse(self.marker.exists())
        return selected

    def username_fact(self, document):
        value = document.get("monero", {}).get("node_username")
        if value is None or value is False:
            return ""
        if isinstance(value, str):
            return value.rstrip("\n")
        if value is True:
            return "true"
        return json.dumps(value, ensure_ascii=False, separators=(",", ":"))

    def encoded(self, document):
        return json.dumps(document, ensure_ascii=False, separators=(",", ":")).encode()

    def result(self, completed):
        return completed.returncode, completed.stdout, completed.stderr

    def state(self, completed):
        fields = completed.stdout.split(b"\0")
        self.assertEqual((len(fields), fields[0], fields[-1]), (4, b"", b""))
        return tuple(value.decode() for value in fields[1:-1])

    def helper(self, mode, parts, binary=None):
        env = {key: value for key, value in os.environ.items() if not key.startswith("PITHEAD_")}
        env.pop("BASH_ENV", None)
        env["PITHEAD_GO_HELPER"] = "config-access-settings"
        return subprocess.run(  # noqa: S603
            [str(binary or GO_BINARY), mode],
            env=env,
            input=b"\0".join(parts) + b"\0",
            capture_output=True,
            check=False,
            timeout=15,
        )

    def make_helper(self, name, body):
        path = self.directory / name
        path.write_text("#!/bin/sh\n" + body)
        path.chmod(0o755)
        return path

    def test_release_ssh_policy_and_callback_order_match_without_jq(self):
        cases = (
            ({}, {"CONFIG_ACCESS_APPLIANCE": "1"}, 0),
            ({"ssh": None}, {"CONFIG_ACCESS_APPLIANCE": "1"}, 0),
            (
                {"ssh": {"enabled": True, "authorized_key": "invalid"}},
                {"CONFIG_ACCESS_APPLIANCE": "1"},
                0,
            ),
            (
                {"ssh": {"enabled": False, "authorized_key": "invalid"}},
                {"CONFIG_ACCESS_APPLIANCE": "1"},
                0,
            ),
            (
                {"ssh": None},
                {"CONFIG_ACCESS_APPLIANCE": "1", "PITHEAD_CONFIG_SET": "1"},
                1,
            ),
            (
                {"ssh": None},
                {
                    "CONFIG_ACCESS_APPLIANCE": "1",
                    "PITHEAD_CONFIG_SET": "1",
                    "PITHEAD_CONFIG_CARRIED_SSH": "1",
                },
                0,
            ),
        )
        for document, extra, rc in cases:
            with self.subTest(document=document, extra=extra):
                selected = self.compare("ssh", document, extra=extra)
                self.assertEqual(selected[0].returncode, rc)
                self.assertEqual(selected[1], b"is-appliance\nvariant\n")

    def test_diy_and_debug_ssh_key_shapes_match(self):
        valid = ("ssh-ed25519 AAA", "ecdsa-sha2-nistp256 AAA", "sk-ssh-ed25519 AAA")
        for key in valid:
            selected = self.compare("ssh", {"ssh": {"enabled": True, "authorized_key": key}})
            self.assertEqual(selected[0].returncode, 0)
            self.assertEqual(selected[1], b"is-appliance\n")
        cases = (
            ({"ssh": {"enabled": False, "authorized_key": "invalid"}}, {}, 0),
            ({"ssh": {"enabled": True, "authorized_key": "invalid"}}, {}, 1),
            (
                {"ssh": {"enabled": "true", "authorized_key": 7}},
                {"CONFIG_ACCESS_APPLIANCE": "1", "CONFIG_ACCESS_VARIANT": "debug"},
                1,
            ),
        )
        for document, extra, rc in cases:
            with self.subTest(document=document):
                selected = self.compare("ssh", document, extra=extra)
                self.assertEqual(selected[0].returncode, rc)

    def test_node_projection_and_generation_plan_match_with_one_username_query(self):
        placeholder_user = "create_a_username_for_node"
        placeholder_pass = "create_a_password_for_node"  # noqa: S105
        cases = (
            (
                {},
                "local",
                ("generated-user", "generated-pass"),
                b"default-user\ngenerate-pass\n",
            ),
            (
                {"monero": {"node_username": "custom-user", "node_password": "custom-pass"}},
                "local",
                ("custom-user", "custom-pass"),
                b"",
            ),
            (
                {"monero": {"node_username": placeholder_user, "node_password": placeholder_pass}},
                "local",
                ("generated-user", "generated-pass"),
                b"default-user\ngenerate-pass\n",
            ),
            (
                {"monero": {"node_username": False, "node_password": 27}},
                "remote",
                ("", "27"),
                b"",
            ),
            (
                {"monero": {"node_username": "line\n\n", "node_password": "pass\n\n"}},
                "remote",
                ("line", "pass"),
                b"",
            ),
        )
        for document, mode, expected, prefix in cases:
            with self.subTest(document=document, mode=mode):
                selected = self.compare(
                    "node",
                    document,
                    extra={"CONFIG_ACCESS_MONERO_MODE": mode},
                    compare_calls=False,
                )
                self.assertEqual((selected[0].returncode, self.state(selected[0])), (0, expected))
                self.assertEqual(len(self.queries.read_text().splitlines()), 1)
                self.assertIn(".monero.node_username // empty", self.queries.read_text())
                if mode == "local" and b"default-user" in prefix:
                    self.assertIn(b"default-user\n", selected[1])
                    self.assertIn(b"generate-pass\n", selected[1])
                else:
                    self.assertTrue(selected[1].startswith(prefix))
                self.assertNotIn(b"custom-pass", selected[1])

    def test_native_node_uses_authoritative_username_query_fact(self):
        document = {"monero": {"node_username": ["unsupported"], "node_password": "pass"}}
        selected = self.invoke(
            "node",
            "go",
            self.encoded(document),
            native=True,
            extra={
                "CONFIG_ACCESS_MONERO_MODE": "remote",
                "CONFIG_ACCESS_USERNAME_FACT": "queried-user",
            },
        )
        self.assertEqual(
            (selected[0].returncode, self.state(selected[0])), (0, ("queried-user", "pass"))
        )
        self.assertEqual(len(self.queries.read_text().splitlines()), 1)
        self.assertFalse(self.marker.exists())

    def test_username_query_failure_stops_before_helper_and_preserves_state(self):
        raw = self.encoded({"monero": {"node_password": "pass"}})
        extra = {
            "CONFIG_ACCESS_ERR_TRAP": "1",
            "CONFIG_ACCESS_USERNAME_FACT": "partial-user",
            "CONFIG_ACCESS_USERNAME_RC": "7",
        }
        baseline = self.invoke("node", "bash", raw, native=True, extra=extra)
        selected = self.invoke("node", "go", raw, native=True, extra=extra)
        self.assertEqual(self.result(selected[0]), self.result(baseline[0]))
        self.assertEqual(selected[1:], baseline[1:])
        self.assertNotEqual(selected[0].returncode, 0)
        self.assertEqual(self.state(selected[0]), ("partial-user", "seed-pass"))
        self.assertNotEqual(selected[2], b"")
        self.assertEqual(len(self.queries.read_text().splitlines()), 1)
        self.assertFalse(self.marker.exists())

    def test_node_callbacks_persist_once_and_preserve_failure_state(self):
        selected = self.compare("node", {}, compare_calls=False)
        self.assertEqual(selected[1].count(b"persist:"), 1)
        self.assertEqual(selected[1].count(b"log\n"), 1)
        cases = (
            ({"CONFIG_ACCESS_DEFAULT_RC": "7"}, ("generated-user", ""), b"default-user\n"),
            (
                {"CONFIG_ACCESS_GENERATE_RC": "8"},
                ("generated-user", "generated-pass"),
                b"generate-pass\n",
            ),
            ({"CONFIG_ACCESS_PERSIST_RC": "9"}, ("generated-user", "generated-pass"), b"persist:"),
        )
        for extra, expected, call in cases:
            with self.subTest(extra=extra):
                selected = self.compare(
                    "node",
                    {},
                    extra={**extra, "CONFIG_ACCESS_ERR_TRAP": "1"},
                    compare_calls=False,
                )
                self.assertNotEqual(selected[0].returncode, 0)
                self.assertEqual(self.state(selected[0]), expected)
                self.assertIn(call, selected[1])
                self.assertNotEqual(selected[2], b"")

    def test_fallbacks_keep_reference_bytes_and_do_not_duplicate_callbacks(self):
        helpers = (
            self.make_helper("refused", "exit 125\n"),
            self.make_helper("empty", "exit 0\n"),
            self.make_helper("truncated", "printf 'user\\0pass\\0true\\0'; exit 0\n"),
            self.make_helper("extra", "printf 'user\\0pass\\0false\\0false\\0extra\\0'; exit 0\n"),
        )
        for operation, document, extra in (
            ("ssh", {"ssh": {"enabled": False}}, {}),
            ("node", {"monero": {"node_username": "u", "node_password": "p"}}, {}),
        ):
            for helper in helpers + (self.directory / "missing",):
                with self.subTest(operation=operation, helper=helper.name):
                    selected = self.compare(
                        operation, document, native=False, binary=helper, extra=extra
                    )
                    if operation == "ssh":
                        self.assertEqual(selected[1].count(b"is-appliance\n"), 1)
                    else:
                        self.assertEqual(selected[1].count(b"needs:user\n"), 1)

    def test_helper_output_is_assigned_literally(self):
        marker = self.directory / "poisoned"
        helper = self.make_helper(
            "literal-output",
            "printf '%s\\0%s\\0false\\0false\\0' '$(touch $CONFIG_ACCESS_POISON_MARKER)' pass\n",
        )
        selected = self.invoke(
            "node",
            "go",
            b"{}",
            binary=helper,
            extra={
                "CONFIG_ACCESS_MONERO_MODE": "remote",
                "CONFIG_ACCESS_POISON_MARKER": str(marker),
            },
        )
        self.assertEqual(selected[0].returncode, 0)
        self.assertEqual(self.state(selected[0]), ("$(touch $CONFIG_ACCESS_POISON_MARKER)", "pass"))
        self.assertFalse(marker.exists())

    def test_helper_protocol_rejects_bad_frames_and_unsupported_json(self):
        raw = self.encoded({"ssh": {"enabled": False}})
        good = self.helper("ssh", (raw, b"false", b"0", b"0", b"0"))
        self.assertEqual((good.returncode, good.stdout, good.stderr), (0, b"\0", b""))
        node = self.helper("node", (b"{}", b"local", b"", b"0"))
        self.assertEqual((node.returncode, node.stderr), (0, b""))
        self.assertEqual(node.stdout.split(b"\0"), [b"", b"", b"true", b"true", b""])
        bad = (
            ("ssh", (raw, b"false", b"0", b"0")),
            ("ssh", (raw, b"false", b"0", b"0", b"1")),
            ("node", (b"{}", b"local", b"")),
            ("node", (b'{"monero":{"node_password":[]}}', b"local", b"user", b"0")),
        )
        for mode, parts in bad:
            with self.subTest(mode=mode, parts=parts):
                completed = self.helper(mode, parts)
                self.assertEqual(
                    (completed.returncode, completed.stdout, completed.stderr), (125, b"", b"")
                )

    def test_go_hook_runs_under_system_bash_when_available(self):
        system_bash = Path("/bin/bash")
        if not system_bash.exists():
            self.skipTest("/bin/bash unavailable")
        selected = self.invoke("node-hook", "go", b"{}", native=True, shell=str(system_bash))
        self.assertEqual(
            (selected[0].returncode, self.state(selected[0])),
            (0, ("seed-user", "")),
        )
        self.assertFalse(self.marker.exists())


if __name__ == "__main__":
    unittest.main(verbosity=2)
