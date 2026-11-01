import copy
import os
import unittest

import test_env_render as render_fixture


class ConfigAccessRenderParityTests(unittest.TestCase):
    def setUp(self):
        self.fixture = render_fixture.EnvRenderParityTests(
            "test_bulk_serialization_matches_dotenv_renderer"
        )
        self.fixture.setUp()
        self.addCleanup(self.fixture.doCleanups)

    def spy(self, name, log, extra=None):
        binary = self.fixture.make_spy(
            name,
            'if "$CONFIG_ACCESS_REAL_GO" "$@"; then rc=0; else rc=$?; fi\n'
            'printf "%s:%s:%s\\n" "${PITHEAD_GO_HELPER:-}" "$#" "$rc" '
            '>>"$CONFIG_ACCESS_SPY_LOG"\nexit "$rc"\n',
        )
        env = {
            "CONFIG_ACCESS_REAL_GO": str(render_fixture.GO_BINARY),
            "CONFIG_ACCESS_SPY_LOG": str(log),
        }
        env.update(extra or {})
        return binary, env

    def test_complete_render_keeps_custom_credentials_and_env_bytes(self):
        document = copy.deepcopy(self.fixture.base_config)
        document["monero"].update(
            node_username="render-user",
            node_password="render-password",  # noqa: S106
        )
        log = self.fixture.directory / "custom-access.spy"
        binary, extra = self.spy("custom-access-spy", log)
        baseline = self.fixture.invoke_render("bash", "custom-access", document, "0")
        selected = self.fixture.invoke_render("go", "custom-access", document, "0", binary, extra)
        self.assertEqual(selected, baseline)
        calls = [
            line
            for line in log.read_text().splitlines()
            if line.startswith("config-access-settings:")
        ]
        self.assertEqual(calls, ["config-access-settings:1:0"] * 2)
        self.assertNotIn(document["monero"]["node_password"], log.read_text())
        self.assertIn(b"MONERO_NODE_USERNAME=render-user\n", selected["env"])
        self.assertIn(b"MONERO_NODE_PASSWORD=render-password\n", selected["env"])

    def test_complete_render_keeps_generated_credentials_and_persistence(self):
        document = copy.deepcopy(self.fixture.base_config)
        document["monero"].update(node_username="", node_password="")
        tools = self.fixture.directory / "access-tools"
        tools.mkdir()
        openssl = tools / "openssl"
        openssl.write_text('#!/bin/sh\nprintf "%064d\\n" 0\n')
        openssl.chmod(0o755)
        path = str(tools) + os.pathsep + os.environ.get("PATH", os.defpath)
        log = self.fixture.directory / "generated-access.spy"
        binary, extra = self.spy("generated-access-spy", log, {"PATH": path})
        baseline = self.fixture.invoke_render(
            "bash", "generated-access", document, "0", extra={"PATH": path}
        )
        selected = self.fixture.invoke_render(
            "go", "generated-access", document, "0", binary, extra
        )
        self.assertEqual(selected, baseline)
        self.assertEqual(selected["process"][0], 0)
        self.assertIn(b"MONERO_NODE_USERNAME=admin\n", selected["env"])
        self.assertIn(b"MONERO_NODE_PASSWORD=00000000000000000000000000000000\n", selected["env"])
        self.assertNotIn("00000000000000000000000000000000", log.read_text())

    def test_invalid_diy_ssh_key_preserves_failure_and_no_env(self):
        document = copy.deepcopy(self.fixture.base_config)
        document["ssh"] = {"enabled": True, "authorized_key": "invalid"}
        log = self.fixture.directory / "invalid-ssh.spy"
        binary, extra = self.spy("invalid-ssh-spy", log)
        baseline = self.fixture.invoke_render("bash", "invalid-ssh", document, "0")
        selected = self.fixture.invoke_render("go", "invalid-ssh", document, "0", binary, extra)
        self.assertEqual(selected, baseline)
        self.assertNotEqual(selected["process"][0], 0)
        self.assertIsNone(selected["env"])
        calls = [
            line
            for line in log.read_text().splitlines()
            if line.startswith("config-access-settings:")
        ]
        self.assertEqual(calls, ["config-access-settings:1:0"])


if __name__ == "__main__":
    unittest.main(verbosity=2)
