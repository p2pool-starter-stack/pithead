import copy
import unittest

import test_env_render as render_fixture

EMOJI = "🐢📟🍼🌈🍓🚓➕🎸🍆🍷🎣🍗📿😂🥊⏰🍯👾🤔👒🍾👀🍼🌊🎷📟😈🚨👙🍈🌈🛵🤢🍔🔋👙🚽🤑🎽🎓🎓🐀🐜🐴🥄🚿📷💰👶👍🎉🍄🎢🔌🐋🚰🚑💅👢🦂🐬🐋🍗🍸🎹🏀🍄"


class WalletSettingsRenderParityTests(unittest.TestCase):
    def setUp(self):
        self.fixture = render_fixture.EnvRenderParityTests(
            "test_bulk_serialization_matches_dotenv_renderer"
        )
        self.fixture.setUp()
        self.addCleanup(self.fixture.doCleanups)

    def spy(self, name, log):
        return self.fixture.make_spy(
            name,
            'if "$WALLET_SETTINGS_REAL_GO" "$@"; then rc=0; else rc=$?; fi\n'
            'printf "%s:%s:%s\\n" "${PITHEAD_GO_HELPER:-}" "$#" "$rc" '
            '>>"$WALLET_SETTINGS_SPY_LOG"\nexit "$rc"\n',
        ), {
            "WALLET_SETTINGS_REAL_GO": str(render_fixture.GO_BINARY),
            "WALLET_SETTINGS_SPY_LOG": str(log),
        }

    def test_unchanged_render_fixture_covers_local_off_and_emoji_wallets(self):
        local = copy.deepcopy(self.fixture.base_config)
        off = copy.deepcopy(local)
        off["tari"].update(mode="off", wallet_address="")
        emoji = copy.deepcopy(local)
        emoji["tari"].update(mode="local", wallet_address=EMOJI)
        for name, document, helper_rc in (
            ("local", local, 0),
            ("off", off, 0),
            ("emoji", emoji, 0),
        ):
            with self.subTest(name=name):
                log = self.fixture.directory / f"{name}.wallet.spy"
                binary, extra = self.spy(f"{name}-wallet-spy", log)
                baseline = self.fixture.invoke_render("bash", name, document, "0")
                selected = self.fixture.invoke_render("go", name, document, "0", binary, extra)
                self.assertEqual(selected, baseline)
                calls = [
                    line
                    for line in log.read_text().splitlines()
                    if line.startswith("config-wallet-settings:")
                ]
                self.assertEqual(calls, [f"config-wallet-settings:0:{helper_rc}"])
                self.assertEqual(selected["process"][0], 0)
                self.assertEqual(selected["env_mode"], 0o600)

    def test_unchanged_render_fixture_preserves_gate_failures_and_no_output(self):
        cases = []
        for name in ("missing-monero", "missing-tari", "bad-mode", "off-whitespace"):
            document = copy.deepcopy(self.fixture.base_config)
            if name == "missing-monero":
                document["monero"]["wallet_address"] = ""
            elif name == "missing-tari":
                document["tari"].update(mode="local", wallet_address="")
            elif name == "bad-mode":
                document["tari"]["mode"] = "bad"
            else:
                document["tari"].update(mode="off", wallet_address="bad value")
            cases.append((name, document))
        for name, document in cases:
            with self.subTest(name=name):
                log = self.fixture.directory / f"{name}.wallet.spy"
                binary, extra = self.spy(f"{name}-wallet-spy", log)
                baseline = self.fixture.invoke_render("bash", name, document, "0")
                selected = self.fixture.invoke_render("go", name, document, "0", binary, extra)
                self.assertEqual(selected, baseline)
                calls = [
                    line
                    for line in log.read_text().splitlines()
                    if line.startswith("config-wallet-settings:")
                ]
                self.assertEqual(calls, ["config-wallet-settings:0:0"])
                self.assertNotEqual(selected["process"][0], 0)
                self.assertIsNone(selected["env"])
                self.assertIsNone(selected["secret"])


if __name__ == "__main__":
    unittest.main(verbosity=2)
