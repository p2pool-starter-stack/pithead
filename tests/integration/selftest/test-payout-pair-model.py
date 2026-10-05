"""The live fixture accepts both Compose environment encodings without losing templates."""

import json
import os
import subprocess
import sys
import unittest
from pathlib import Path

TRANSFORM = Path(__file__).resolve().parents[1] / "payout-pairs/compose.py"
ENV = {"UNCHANGED": "${TEMPLATE:-a=b}", "BARE": None, "MONERO_NODE_HOST": "${OLD_HOST}"}


class ModelTest(unittest.TestCase):
    def model(self, lists):
        services = {}
        for name in ("wallet-rpc", "tari-wallet", "dashboard"):
            env = (
                [key if value is None else f"{key}={value}" for key, value in ENV.items()]
                if lists
                else ENV.copy()
            )
            services[name] = {
                "image": "fixture:test",
                "environment": env,
                "container_name": name,
                "depends_on": {"tari": {"condition": "service_healthy"}},
                "profiles": ["payout"],
                "ports": ["1234:1234"],
                "volumes": ["wallet_data:/wallets"],
                "cap_drop": ["ALL"],
                "healthcheck": {"test": ["CMD-SHELL", 'test -n "$$UNCHANGED"']},
            }
        return {
            "services": services,
            "networks": {"mining_net": {"name": "fixture-shared"}},
            "secrets": {"tari_wallet_secret": {"file": "./build/tari/view-only.secret"}},
        }

    def transform(self, lists):
        result = subprocess.run(  # noqa: S603 — fixed repository transformer, synthetic JSON
            [
                sys.executable,
                str(TRANSFORM),
                "fixture-private",
                "node-fixture",
                "tari-fixture:18142",
            ],
            input=json.dumps(self.model(lists)),
            env={**os.environ, "PYTHONPATH": ""},
            capture_output=True,
            text=True,
            timeout=10,
            check=False,
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        return json.loads(result.stdout)

    def assert_model(self, model):
        self.assertEqual(model["name"], "fixture-private")
        self.assertEqual(set(model["services"]), {"wallet-rpc", "tari-wallet", "dashboard"})
        for service in model["services"].values():
            env = service["environment"]
            self.assertEqual(env["UNCHANGED"], "${TEMPLATE:-a=b}")
            self.assertIsNone(env["BARE"])
            self.assertEqual(service["cap_drop"], ["ALL"])
            self.assertEqual(service["healthcheck"]["test"][1], 'test -n "$$UNCHANGED"')
            for key in ("container_name", "depends_on", "profiles", "ports"):
                self.assertNotIn(key, service)
        self.assertEqual(
            model["services"]["wallet-rpc"]["environment"]["MONERO_NODE_HOST"], "node-fixture"
        )
        self.assertEqual(
            model["services"]["tari-wallet"]["environment"]["TARI_BASE_NODE_GRPC_ADDRESS"],
            "tari-fixture:18142",
        )
        self.assertEqual(
            model["networks"]["mining_net"], {"external": True, "name": "fixture-shared"}
        )
        self.assertEqual(
            model["secrets"]["tari_wallet_secret"]["file"], "./build/tari/view-only.secret"
        )

    def test_raw_list_environment_preserves_values_and_isolation(self):
        self.assert_model(self.transform(lists=True))

    def test_normalized_mapping_environment_keeps_same_contract(self):
        self.assert_model(self.transform(lists=False))


if __name__ == "__main__":
    unittest.main()
