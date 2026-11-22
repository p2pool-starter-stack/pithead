import importlib
import json
import os
from pathlib import Path
from unittest.mock import patch


def _reload_config():
    import mining_dashboard.config.config as cfg

    return importlib.reload(cfg)


class TestDonationConfig:
    def teardown_method(self):
        _reload_config()

    def test_donation_defaults_are_dark_and_match_the_reference(self):
        env = {k: v for k, v in os.environ.items() if not k.startswith("DONATION_")}
        with patch.dict(os.environ, env, clear=True):
            cfg = _reload_config()
        reference = json.loads(
            (Path(__file__).resolve().parents[3] / "config.reference.json").read_text()
        )
        assert reference["donation"] == {"enabled": False, "percent": 0, "tor": True}
        assert (cfg.DONATION_ENABLED, cfg.DONATION_PERCENT, cfg.DONATION_TOR_ENABLED) == (
            False,
            0.0,
            True,
        )

    def test_donation_env_override(self):
        env = {
            "DONATION_ENABLED": "true",
            "DONATION_PERCENT": "2.5",
            "DONATION_TOR_ENABLED": "false",
        }
        with patch.dict(os.environ, env):
            cfg = _reload_config()
            assert cfg.DONATION_ENABLED is True
            assert cfg.DONATION_PERCENT == 2.5
            assert cfg.DONATION_TOR_ENABLED is False
