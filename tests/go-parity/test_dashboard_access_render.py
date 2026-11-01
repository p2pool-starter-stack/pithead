import copy
import unittest

import test_env_dashboard as render_fixture


class DashboardAccessRenderParityTests(unittest.TestCase):
    def test_unchanged_render_fixture_with_access_settings(self):
        fixture = render_fixture.EnvDashboardParityTests(
            "test_private_protocol_returns_52_fields_and_refuses_bad_frames"
        )
        fixture.setUp()
        self.addCleanup(fixture.doCleanups)
        cases = [
            {},
            {
                "host": "panel.example",
                "port": 8443,
                "secure": False,
                "expose_public_ip": True,
                "timezone": "Asia/Tokyo",
            },
            {
                "host": "DYNAMIC_HOST",
                "port": "DYNAMIC_DATA",
                "secure": "yes",
                "expose_public_ip": "ON",
                "timezone": "DYNAMIC_ID",
            },
        ]
        for platform in ("0", "1"):
            for index, settings in enumerate(cases):
                with self.subTest(platform=platform, settings=settings):
                    name = f"access-{platform}-{index}"
                    document = copy.deepcopy(fixture.base_config)
                    document.setdefault("dashboard", {}).update(settings)
                    log = fixture.directory / f"{name}.log"
                    spy = fixture.forwarding_spy(f"{name}-spy")
                    baseline = fixture.invoke("bash", name, document, platform)
                    selected = fixture.invoke(
                        "go",
                        name,
                        document,
                        platform,
                        spy,
                        {
                            "DASHBOARD_REAL_GO": str(render_fixture.GO_BINARY),
                            "DASHBOARD_SPY_LOG": str(log),
                        },
                    )
                    self.assertEqual(selected, baseline)
                    self.assertEqual(selected["process"][0], 0)
                    self.assertEqual(selected["env_mode"], 0o600)
                    self.assertEqual(
                        log.read_text().splitlines().count("config-dashboard-access:0:0"), 1
                    )


if __name__ == "__main__":
    unittest.main(verbosity=2)
