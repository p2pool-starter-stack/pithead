import copy
import unittest

import test_env_render as render_fixture


class PayoutSettingsRenderParityTests(unittest.TestCase):
    def test_unchanged_render_fixture_uses_native_payout_settings(self):
        fixture = render_fixture.EnvRenderParityTests(
            "test_bulk_serialization_matches_dotenv_renderer"
        )
        fixture.setUp()
        self.addCleanup(fixture.doCleanups)
        profiles = fixture.render_cases()["payout-profiles"]
        birthday = copy.deepcopy(profiles[0])
        birthday["tari"]["payout_scan_birthday"] = 1000
        cases = [
            ("default", fixture.base_config, "0", []),
            (
                "profiles",
                profiles[0],
                profiles[1],
                ["config-payout-settings:birthday:1:0"],
            ),
            (
                "birthday",
                birthday,
                profiles[1],
                ["config-payout-settings:birthday:1:0"],
            ),
        ]
        for name, document, platform, birthday_calls in cases:
            with self.subTest(name=name):
                log = fixture.directory / f"{name}.payout.spy"
                spy = fixture.make_spy(
                    f"{name}-payout-spy",
                    'if "$PAYOUT_SETTINGS_REAL_GO" "$@"; then rc=0; else rc=$?; fi\n'
                    'printf "%s:%s:%s:%s\\n" "${PITHEAD_GO_HELPER:-}" "${1:-}" "$#" "$rc" '
                    '>>"$PAYOUT_SETTINGS_SPY_LOG"\nexit "$rc"\n',
                )
                baseline = fixture.invoke_render("bash", name, document, platform)
                selected = fixture.invoke_render(
                    "go",
                    name,
                    document,
                    platform,
                    spy,
                    {
                        "PAYOUT_SETTINGS_REAL_GO": str(render_fixture.GO_BINARY),
                        "PAYOUT_SETTINGS_SPY_LOG": str(log),
                    },
                )
                self.assertEqual(selected, baseline)
                calls = log.read_text().splitlines()
                self.assertEqual(calls.count("config-payout-settings:monero:1:0"), 1)
                self.assertEqual(calls.count("config-payout-settings:tari:1:0"), 1)
                for expected in birthday_calls:
                    self.assertEqual(calls.count(expected), 1)
                if not birthday_calls:
                    self.assertFalse(any(":birthday:" in call for call in calls))
                self.assertNotIn(render_fixture.VIEW_KEY, log.read_text())
                self.assertEqual(selected["env_mode"], 0o600)
                self.assertEqual(selected["secret_mode"], 0o600)


if __name__ == "__main__":
    unittest.main(verbosity=2)
