import unittest
from pathlib import Path

import test_caddy

ROOT = Path(__file__).resolve().parents[2]
ADAPTER = ROOT / "tests/go-parity/site_names_caddy_reference.sh"


class SiteNamesRenderParityTests(unittest.TestCase):
    def setUp(self):
        self.fixture = test_caddy.CaddyParityTests(methodName="runTest")
        self.fixture.setUp()
        self.addCleanup(self.fixture.doCleanups)

    def invoke(self, implementation, name, case, binary=None, extra_env=None):
        original = test_caddy.ADAPTER
        test_caddy.ADAPTER = ADAPTER
        try:
            return self.fixture.invoke(implementation, name, case, binary, extra_env=extra_env)
        finally:
            test_caddy.ADAPTER = original

    def make_spy(self):
        return self.fixture.make_spy(
            "site-render-spy",
            'if "$CADDY_REAL_GO" "$@"; then rc=0; else rc=$?; fi\n'
            'printf "%s:%s:%s\\n" "${PITHEAD_GO_HELPER:-}" "${1:-}" "$rc" '
            '>>"$CADDY_SPY_LOG"\n'
            'exit "$rc"\n',
        )

    def cases(self):
        appliance = {
            "CADDY_APPLIANCE": "true",
            "CADDY_HOSTNAME": "rig",
            "HOST_IP": "rig.local",
            "DASHBOARD_HOST": "",
            "CADDY_HOSTNAME_LABEL": "",
        }
        return {
            "auto-http": (
                {
                    **appliance,
                    "HOST_PORT": "8080",
                    "CADDY_HOSTNAME_ADDRESSES": "192.168.2.50",
                },
                b"http://rig.local:8080, http://192.168.2.50:8080, http://localhost:8080 {",
                True,
            ),
            "filtered-private-bridge-public": (
                {
                    **appliance,
                    "DASHBOARD_SECURE": "true",
                    "CADDY_HOSTNAME_ADDRESSES": (
                        "192.168.2.50 172.19.0.1 172.28.0.1 8.8.8.8 fd00:2463::1 2606:4700::1111"
                    ),
                    "CADDY_BRIDGE_ADDRESSES": "172.19.0.1",
                },
                b"https://rig.local, https://192.168.2.50, https://fd00:2463::1, https://localhost {",
                True,
            ),
            "public-opt-in": (
                {
                    **appliance,
                    "DASHBOARD_SECURE": "true",
                    "DASHBOARD_EXPOSE_PUBLIC_IP": "true",
                    "CADDY_HOSTNAME_ADDRESSES": "8.8.8.8 2606:4700::1111",
                },
                b"https://rig.local, https://8.8.8.8, https://2606:4700::1111, https://localhost {",
                True,
            ),
            "pinned-https": (
                {
                    **appliance,
                    "DASHBOARD_SECURE": "true",
                    "HOST_PORT": "8443",
                    "HOST_IP": "panel.example",
                    "DASHBOARD_HOST": "panel.example",
                    "CADDY_HOSTNAME_ADDRESSES": "192.168.2.50",
                },
                b"https://panel.example:8443 {",
                False,
            ),
            "label-expands": (
                {
                    **appliance,
                    "HOST_IP": "rig-2",
                    "DASHBOARD_HOST": "RIG-2",
                    "CADDY_HOSTNAME_LABEL": "rig-2",
                    "CADDY_HOSTNAME_ADDRESSES": "10.0.0.2",
                },
                b"http://rig-2, http://10.0.0.2, http://localhost {",
                True,
            ),
            "empty-diy": (
                {
                    "CADDY_APPLIANCE": "false",
                    "CADDY_HOSTNAME": "",
                    "HOST_IP": "",
                    "DASHBOARD_HOST": "",
                },
                b" {\n",
                False,
            ),
            "onion-auth": (
                {
                    **appliance,
                    "DASHBOARD_SECURE": "true",
                    "CADDY_HOSTNAME_ADDRESSES": "10.0.0.2",
                    "DASHBOARD_AUTH_HASH_B64": test_caddy.HASH_B64,
                    "DASHBOARD_ONION_ENABLED": "true",
                    "DASHBOARD_ONION": (
                        "parityexample234567890123456789012345678901234567890123.onion"
                    ),
                },
                b"https://rig.local, https://10.0.0.2, https://localhost {",
                True,
            ),
        }

    def test_complete_caddy_output_matches_production_site_names(self):
        spy = self.make_spy()
        spy_log = self.fixture.directory / "site-render-spy.log"
        for name, (case, expected, expands) in self.cases().items():
            with self.subTest(case=name):
                baseline = self.invoke("bash", name, case)
                spy_log.write_bytes(b"")
                selected = self.invoke(
                    "go",
                    name,
                    case,
                    spy,
                    {
                        "CADDY_REAL_GO": str(test_caddy.GO_BINARY),
                        "CADDY_SPY_LOG": str(spy_log),
                    },
                )
                self.assertEqual(selected, baseline)
                self.assertEqual(baseline[0], 0)
                self.assertIn(expected, baseline[4])
                invocations = spy_log.read_bytes().splitlines()
                expand = b"config-site-names:expand:0"
                self.assertEqual(expand in invocations, expands)
                self.assertTrue(any(line.startswith(b"config-caddy:") for line in invocations))


if __name__ == "__main__":
    unittest.main()
