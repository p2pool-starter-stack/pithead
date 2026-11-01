import copy
import unittest

import test_env_dashboard as render_fixture


class DirectoryRenderParityTests(unittest.TestCase):
    def test_unchanged_render_fixture_with_directory_layouts(self):
        fixture = render_fixture.EnvDashboardParityTests(
            "test_private_protocol_returns_52_fields_and_refuses_bad_frames"
        )
        fixture.setUp()
        self.addCleanup(fixture.doCleanups)
        root = fixture.directory / "data-layout"
        shared = {
            name: {"data_dir": str(root / "shared" / name)}
            for name in ("monero", "tari", "p2pool", "tor")
        }
        scattered = {
            name: {"data_dir": str(root / name / "state")}
            for name in ("monero", "tari", "p2pool", "tor")
        }
        pinned = {**shared, "dashboard": {"data_dir": str(root / "panel")}}
        trailing = {
            name: {"data_dir": str(root / "trailing" / name) + "/"}
            for name in ("monero", "tari", "p2pool", "tor")
        }
        cases = [({}, 0), (shared, 0), (scattered, 0), (pinned, 0), (trailing, 0)]
        for spelling in ("/a/../b", "/a/./b", "/a//b", "/a/b:ro"):
            cases.append(({"monero": {"data_dir": str(root) + spelling}}, 1))
        for platform in ("0", "1"):
            for index, (settings, expected_status) in enumerate(cases):
                with self.subTest(platform=platform, settings=settings):
                    name = f"directories-{platform}-{index}"
                    document = copy.deepcopy(fixture.base_config)
                    for section, values in settings.items():
                        document.setdefault(section, {}).update(values)
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
                    self.assertEqual(selected["process"][0], expected_status)
                    self.assertEqual(
                        log.read_text().splitlines().count("config-directories:0:0"), 1
                    )
                    if expected_status == 0:
                        self.assertEqual(selected["env_mode"], 0o600)
                        self.assertEqual(selected["secret_mode"], 0o600)
                    else:
                        self.assertIsNone(selected["env"])
                        self.assertIsNone(selected["secret"])


if __name__ == "__main__":
    unittest.main(verbosity=2)
