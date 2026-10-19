"""CLI raw parser regressions; dashboard image tests own the Python decoder."""

import json
import re
import shutil
import subprocess
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[3]
BASH = shutil.which("bash")
if BASH is None:
    raise RuntimeError("bash is required for CLI parser tests")

SECRETS = [
    "dashboard.auth.password",
    "telegram.bot_token",
    "telegram.chat_id",
    "monero.node_username",
    "monero.node_password",
    "monero.view_key",
    "tari.view_key",
    "tari.spend_public_key",
    "workers.api_token",
    "workers.api_auth",
    "p2pool.stratum_password",
    "healthchecks.ping_url",
    "notifications.ntfy.url",
    "notifications.ntfy.token",
    "xvb.standby.source",
    "workers.list[0].token",
    "workers.list[0].api_token",
    "notifications.webhooks[0]",
    "dashboard.host",
    "monero.wallet_address",
    "tari.wallet_address",
]


def candidate(path, value):
    cfg = value
    for part in reversed(path.split(".")):
        match = re.fullmatch(r"(.+)\[0\]", part)
        cfg = {match[1]: [cfg]} if match else {part: cfg}
    return cfg


class DocumentParserTests(unittest.TestCase):
    def parse(self, text, request=False, missing=False):
        with tempfile.TemporaryDirectory() as scratch:
            path = Path(scratch) / "config.json"
            if not missing:
                path.write_text(text)
            result = subprocess.run(  # noqa: S603 — fixed shell source, untrusted file never becomes code
                [
                    BASH,
                    "-c",
                    'source "$1"; config_document_error "$2" "$3"',
                    "test",
                    str(ROOT / "lib/pithead/22a-config-document.sh"),
                    str(path),
                    "request" if request else "config",
                ],
                text=True,
                capture_output=True,
                check=False,
            )
            self.assertEqual(result.stderr, "")
            return result

    def rejected(self, text, path, message, **kwargs):
        result = self.parse(text, **kwargs)
        self.assertEqual(result.returncode, 1)
        self.assertIn(path, result.stdout)
        self.assertIn(message, result.stdout)
        return result.stdout

    def test_duplicates(self):
        for text, path in [
            ('{"monero":{},"monero":{}}', "monero"),
            (
                '{"dashboard":{"auth":{"password":"first","password":"last"}}}',
                "dashboard.auth.password",
            ),
            ('{"workers":{"list":[{"token":"first","token":"last"}]}}', "workers.list[0].token"),
            ('{"monero":{},"\\u006donero":{}}', "monero"),
            ('{"a":{"x":1},"a":{"y":2}}', "a"),
            ('{"a":null,"a":0}', "a"),
        ]:
            with self.subTest(text=text):
                output = self.rejected(text, path, "duplicate key")
                self.assertNotIn("first", output)
                self.assertNotIn("last", output)

    def test_placeholders(self):
        for path in SECRETS:
            for value in ["PASTE_secret", "your_secret", "pAsTe_secret", "YoUr_secret"]:
                with self.subTest(path=path, value=value):
                    output = self.rejected(
                        json.dumps(candidate(path, value)), path, "placeholder value"
                    )
                    self.assertNotIn(value, output)

    def test_valid_documents(self):
        for cfg in [
            {"a": {"x": 1}, "b": {"x": 2}},
            {"workers": [{"token": "opaque"}, {"token": "another"}]},
            {
                "enabled": False,
                "unset": None,
                "password": "",
                "host": "auto",
                "text": "prefix_YOUR_",
            },
            {"dashboard": {"auth": {"password": {"__secret__": True}}}},
        ]:
            with self.subTest(cfg=cfg):
                self.assertEqual(self.parse(json.dumps(cfg)).returncode, 0)

    def test_request(self):
        self.assertEqual(
            self.parse(
                '{"actor":"YOUR_user","config":{"telegram":{"bot_token":"opaque"}}}', request=True
            ).returncode,
            0,
        )
        self.rejected(
            '{"config":{"dashboard":{"host":"PASTE_host"}}}',
            "dashboard.host",
            "placeholder value",
            request=True,
        )
        self.rejected('{"config":{},"config":{}}', "config", "duplicate key", request=True)

    def test_malformed_and_unreadable(self):
        for text in ["{", '{"a":', "[]\n{}"]:
            with self.subTest(text=text):
                self.rejected(text, "", "not valid JSON")
        self.rejected("", "", "could not read config document", missing=True)

    def test_diagnostic_controls(self):
        output = self.rejected('{"bad\\nkey":{"secret":"YOUR_value"}}', "", "placeholder value")
        self.assertEqual(len(output.splitlines()), 1)
        self.assertNotIn("YOUR_value", output)

    def test_deep_document(self):
        self.rejected('{"value":' + "[" * 1200 + "0" + "]" * 1200 + "}", "", "nested too deeply")


if __name__ == "__main__":
    unittest.main()
