import importlib
import re
from pathlib import Path

import pytest

from mining_dashboard.config import config

ROOT = Path(__file__).resolve().parents[4]


def host_list():
    text = (ROOT / "lib/pithead/46a-control-diagnostics.sh").read_text()
    match = re.search(r'^readonly PITHEAD_DIAG_CONTAINERS="([^"]*)"', text, re.M)
    assert match
    return match.group(1).split()


def test_the_host_allowlist_excludes_the_wallet_daemons():
    names = host_list()
    assert names
    assert not {"wallet-rpc", "tari-wallet"} & set(names)


def test_compose_passes_the_host_constant_and_mode_to_the_dashboard():
    compose = (ROOT / "docker-compose.yml").read_text()
    block = compose.split("\n  dashboard:\n", 1)[1].split("\n  docker-proxy:", 1)[0]
    assert "- PITHEAD_DIAG_CONTAINERS=${PITHEAD_DIAG_CONTAINERS:-}" in block
    assert "- DASHBOARD_MODE=${DASHBOARD_MODE:-dashboard}" in block


@pytest.mark.parametrize("profile", ["", "local/", "payout/"])
def test_the_appliance_renderer_fixtures_carry_the_same_list(profile):
    expected = ",".join(host_list())
    base = ROOT / "os/quadlet" / profile
    env = (base / "fixture.env").read_text()
    assert f"\nPITHEAD_DIAG_CONTAINERS={expected}\n" in env
    unit = (base / "dashboard.container").read_text()
    assert f'"PITHEAD_DIAG_CONTAINERS={expected}"' in unit
    assert '"DASHBOARD_MODE=dashboard"' in unit


@pytest.fixture
def reloaded():
    yield lambda: importlib.reload(config)
    importlib.reload(config)


def test_config_splits_the_rendered_list_and_defaults_to_dashboard_mode(monkeypatch, reloaded):
    monkeypatch.delenv("DASHBOARD_MODE", raising=False)
    monkeypatch.setenv("PITHEAD_DIAG_CONTAINERS", ",".join(host_list()))
    cfg = reloaded()
    assert cfg.LOG_API_SERVICES == tuple(host_list())
    assert cfg.DASHBOARD_MODE == "dashboard"


def test_an_unset_list_allows_no_service(monkeypatch, reloaded):
    monkeypatch.delenv("PITHEAD_DIAG_CONTAINERS", raising=False)
    assert reloaded().LOG_API_SERVICES == ()
