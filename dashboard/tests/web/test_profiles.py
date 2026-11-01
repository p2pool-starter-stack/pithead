import json
import os
import subprocess
import sys

import pytest

from mining_dashboard.config.defaults import profile_config, select_profile
from mining_dashboard.wizard.defaults import explicit_wizard_config, new_machine_answers
from mining_dashboard.wizard.form import build_config


@pytest.mark.parametrize("profile", ["performance", "balance", "privacy"])
def test_profile_defaults_and_explicit_overrides(profile):
    cfg = profile_config({"profile": profile})
    assert cfg["p2pool"]["clearnet"] is (profile == "performance")
    assert cfg["network"]["tor_egress_firewall"] is (profile != "performance")
    assert cfg["tor"]["auto_heal"] is (profile != "performance")
    assert cfg["workers"]["api_auth"] == ("token" if profile == "privacy" else "none")
    assert cfg["p2pool"]["stratum_password"] == ("auto" if profile == "privacy" else "")
    cfg = profile_config({"profile": profile, "p2pool": {"clearnet": False}})
    assert cfg["p2pool"]["clearnet"] is False


def test_selection_clears_governed_values_and_keeps_unrelated_values():
    cfg = {"p2pool": {"clearnet": False, "pool": "nano"}, "workers": {"api_token": "old"}}
    selected = select_profile(cfg, "privacy")
    assert selected == {"profile": "privacy", "p2pool": {"pool": "nano"}, "workers": {}}
    assert cfg["workers"]["api_token"] == "old"
    assert profile_config(selected)["workers"]["api_token"] == "auto"


def test_wizard_writes_balance_without_governed_overrides():
    answers = new_machine_answers({}, [])
    for cfg in (explicit_wizard_config(answers, {}), build_config({})):
        assert cfg["profile"] == "balance"
        assert "clearnet_initial_sync" not in cfg.get("monero", {})
        assert "stratum_password" not in cfg.get("p2pool", {})


@pytest.mark.parametrize("profile", ["performance", "balance", "privacy"])
def test_process_routes_all_profile_clients(profile):
    script = """
import json
from unittest.mock import Mock
from mining_dashboard.config import config
from mining_dashboard.service.data_service import DataService
from mining_dashboard.service.notify.telegram_notifier import TelegramNotifier
from mining_dashboard.service.notify.healthchecks import HealthchecksClient
from mining_dashboard.client.xvb_client import XvbClient
service = DataService(Mock(), Mock(), Mock())
print(json.dumps({
    "release": service.update_checker.client.tor_proxy,
    "rigforge": service.rigforge_update_checker.client.tor_proxy,
    "price": service.price_feed.client.tor_proxy,
    "telegram": TelegramNotifier()._proxies,
    "healthchecks": HealthchecksClient.from_config()._proxies,
    "xvb": XvbClient("fixture").tor_proxy,
}))
"""
    env = {
        **os.environ,
        "PITHEAD_PROFILE": profile,
        "NOTIFY_TOR": str(profile != "performance").lower(),
        "XVB_TOR_ENABLED": str(profile != "performance").lower(),
    }
    result = subprocess.run(  # noqa: S603
        [sys.executable, "-c", script], env=env, capture_output=True, text=True
    )
    assert result.returncode == 0, result.stderr
    routes = json.loads(result.stdout)
    for route in routes.values():
        if profile == "performance":
            assert not route
        elif isinstance(route, dict):
            assert route["http"].startswith("socks5h://")
        else:
            assert route.startswith("socks5h://")


def test_performance_honors_explicit_xvb_tor_override():
    script = "from mining_dashboard.client.xvb_client import XvbClient; assert XvbClient('fixture').tor_proxy.startswith('socks5h://')"
    result = subprocess.run(  # noqa: S603
        [sys.executable, "-c", script],
        env={**os.environ, "PITHEAD_PROFILE": "performance", "XVB_TOR_ENABLED": "true"},
        capture_output=True,
        text=True,
    )
    assert result.returncode == 0, result.stderr


@pytest.mark.parametrize("invalid", ["unknown", 17, {}, []])
def test_malformed_profile_remains_editable_for_host_rejection(invalid):
    assert profile_config({"profile": invalid}) == {"profile": invalid}


@pytest.mark.parametrize("invalid", [None, 17, "bad", []])
def test_malformed_blocks_remain_available_for_host_rejection(invalid):
    assert profile_config({"p2pool": invalid})["p2pool"] == invalid


def test_wizard_selection_clears_old_overrides_but_same_profile_keeps_advanced_values():
    cfg = {"profile": "privacy", "p2pool": {"clearnet": True, "pool": "mini"}}
    assert explicit_wizard_config(cfg, {})["p2pool"] == {"pool": "mini"}
    assert explicit_wizard_config(cfg, {}, previous_profile="privacy")["p2pool"]["clearnet"] is True
