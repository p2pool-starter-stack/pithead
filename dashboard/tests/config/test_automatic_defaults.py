import importlib

import pytest

from mining_dashboard.config import config
from mining_dashboard.config.defaults import TABLE


@pytest.mark.parametrize("enabled,percent,tor", [(None, None, None), ("true", "10", "false")])
def test_donation_runtime_defaults_and_overrides(monkeypatch, enabled, percent, tor):
    for key, value in zip(
        ("DONATION_ENABLED", "DONATION_PERCENT", "DONATION_TOR_ENABLED"),
        (enabled, percent, tor),
        strict=True,
    ):
        if value is None:
            monkeypatch.delenv(key, raising=False)
        else:
            monkeypatch.setenv(key, value)
    importlib.reload(config)
    assert config.DONATION_ENABLED is (enabled == "true")
    assert config.DONATION_PERCENT == (2 if percent is None else 10)
    assert config.DONATION_TOR_ENABLED is (tor != "false")
    monkeypatch.undo()
    importlib.reload(config)


@pytest.mark.parametrize(
    "monero,tari,miner,expected",
    [
        (False, None, False, 3),
        (True, None, False, 8),
        (True, True, False, 14),
        (True, True, True, 17),
    ],
)
def test_memory_floor_uses_shared_constant(monkeypatch, monero, tari, miner, expected):
    monkeypatch.setattr(config, "_LOW_RAM_ENV", None)
    monkeypatch.setattr(config, "local_miner_enabled", lambda: miner)
    assert config.LOW_RAM_GB == TABLE["runtime"]["low_ram_gb"]
    assert config.low_ram_floor_gb(monero, tari) == expected
