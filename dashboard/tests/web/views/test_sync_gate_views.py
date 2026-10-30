import pytest

from mining_dashboard.config import config
from mining_dashboard.web.views.views import build_state


@pytest.mark.parametrize(
    "mode, required, monero_only, gating",
    [
        ("off", False, False, False),
        ("local", False, False, False),
        ("local", True, False, True),
        ("remote", True, True, False),
    ],
)
def test_effective_tari_sync_gate(
    mode, required, monero_only, gating, _data, _state_mgr, monkeypatch
):
    monkeypatch.setattr(config, "TARI_MODE", mode)
    monkeypatch.setattr(config, "TARI_REQUIRED", required)
    state = build_state(
        _data(
            global_sync=True,
            sync_gate_monero_only=monero_only,
            monero_sync={"is_syncing": True, "percent": 42, "current": 42, "target": 100},
            tari_sync={"is_syncing": True, "percent": 0, "current": 0, "target": 0},
        ),
        _state_mgr(),
        "all",
    )
    assert state["syncing"] is True
    assert state["tari_gates_sync"] is gating
    assert state["sync"]["monero"]["percent"] == 42
    assert state["sync"]["tari"]["state"] == "loading"
