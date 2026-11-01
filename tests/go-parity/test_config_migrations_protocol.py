import os
import subprocess
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
GO_BINARY = ROOT / "go/bin/pithead"
KEYS = b'["enabled","url","donor_id"]'
DEFAULTS = b'{"enabled":true,"url":"na.xmrvsbeast.com:4247","donor_id":"auto"}'


class ConfigMigrationsProtocolTests(unittest.TestCase):
    def helper(self, operation, payload):
        env = {key: value for key, value in os.environ.items() if not key.startswith("PITHEAD_")}
        env["PITHEAD_GO_HELPER"] = "config-migrations"
        return subprocess.run(  # noqa: S603
            [str(GO_BINARY), operation],
            env=env,
            input=payload,
            capture_output=True,
            check=False,
            timeout=15,
        )

    def workers(self, raw, status=b"0"):
        return raw + b"\0" + KEYS + b"\0" + DEFAULTS + b"\0" + status + b"\0"

    def telegram(self, raw, status=b"0"):
        return raw + b"\0" + status + b"\0"

    def test_success_frames(self):
        plan = self.helper("workers-plan", self.workers(b'{"xmrig_proxy":{"enabled":false}}'))
        self.assertEqual((plan.returncode, plan.stdout), (0, b"\0true\0true\0"))
        tplan = self.helper(
            "telegram-plan", self.telegram(b'{"telegram":{"control":{"enabled":true}}}')
        )
        self.assertEqual((tplan.returncode, tplan.stdout), (0, b"true\0true\0"))

    def test_bad_frames_producer_failures_and_unsupported_values_are_silent(self):
        good = self.workers(b'{"xmrig_proxy":{"enabled":false}}')
        cases = (
            self.helper("workers-plan", good[:-1]),
            self.helper("workers-json", good + b"x"),
            self.helper("workers-plan", self.workers(b"{}", b"1")),
            self.helper("workers-plan", self.workers(b'{"xmrig_proxy":{"url":1.0}}')),
            self.helper("telegram-plan", self.telegram(b"{}", b"1")),
            self.helper(
                "telegram-plan",
                self.telegram(b'{"telegram":{"control":{"enabled":"true\\u0000"}}}'),
            ),
            self.helper("telegram-json", b"{}\0"),
            self.helper("unknown", b""),
        )
        for completed in cases:
            self.assertEqual(
                (completed.returncode, completed.stdout, completed.stderr), (125, b"", b"")
            )


if __name__ == "__main__":
    unittest.main(verbosity=2)
