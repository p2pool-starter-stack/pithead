import mining_dashboard.config.config as cfg
from mining_dashboard.web.views.views import build_state


def test_build_state_names_the_apt_command_only_on_an_apt_install(_data, _state_mgr, monkeypatch):
    state = build_state(_data(), _state_mgr(), "all")
    assert state["apt_update_command"] is None
    monkeypatch.setattr(cfg, "INSTALL_ROUTE", "apt")
    state = build_state(_data(), _state_mgr(), "all")
    assert state["apt_update_command"] == "sudo apt update && sudo apt upgrade"
