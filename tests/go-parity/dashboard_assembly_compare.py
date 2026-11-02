from dataclasses import replace
from unittest.mock import MagicMock

import dashboard_assembly_plugin as adapter
from tests.web.conftest import _BASE

from mining_dashboard.web.views import views

# ruff: noqa: S101

pytest_plugins = ["dashboard_assembly_plugin"]

EXPECTED_KEYS = [
    "syncing",
    "tari_gates_sync",
    "page_title",
    "host_ip",
    "host_addr",
    "dashboard_onion",
    "stratum_connected",
    "version",
    "update",
    "control_enabled",
    "os_update",
    "last_update",
    "range",
    "window",
    "avg_window",
    "avg_windows",
    "badges",
    "db_healthy",
    "hashrate",
    "system",
    "host_resources",
    "sync",
    "sync_status",
    "stratum",
    "pool",
    "network",
    "monero",
    "shares_window",
    "cadence",
    "raffle_eligible",
    "raffle_wins",
    "proxy_workers",
    "earnings",
    "earnings_summary",
    "xvb_calc",
    "xvb_standby",
    "tari",
    "workers",
    "energy",
    "proxy_summary",
    "share_stats",
    "reject_pct_24h",
    "blocks",
    "payouts",
    "disk_growth",
    "xvb_history",
    "egress",
    "topology",
    "chart",
]


class RawValue:
    pass


def _snapshot():
    return {
        "now": 1000.0,
        "payout_confirm_enabled": False,
        "tari_payout_confirm_enabled": False,
        "egress": {"summary": {"level": "ok", "leaks": [], "label": "Tor only"}},
        "topology": {"kind": "fixture"},
        "host_ip": "host.example.com",
        "host_addr": "host.example.com",
        "dashboard_onion": "fixture.onion",
        "stratum": {
            "stratum_connected": RawValue(),
            "host_ip": "stratum.example.com",
        },
        "version": {"text": "v1.2.3"},
        "control_enabled": True,
        "os_update": {"step": "ready"},
        "last_update": "frozen",
        "tari_required": True,
    }


def _data(**values):
    data = {
        "shares": [],
        "workers": [],
        "global_sync": False,
        "total_live_h15": 0,
        "monero_sync": {"percent": 100, "current": 10, "target": 10},
        "tari_sync": {"percent": 50, "current": 5, "target": 10},
    }
    data.update(values)
    return data


def _metrics(**values):
    return replace(_BASE, **values)


def _manager():
    manager = MagicMock()
    manager.get_history.return_value = []
    manager.get_xvb_stats.return_value = {"current_mode": "P2POOL"}
    manager.get_tiers.return_value = {}
    manager.get_xvb_reward_estimates.return_value = {"estimates": {}, "last_update": 0.0}
    manager.get_xvb_round_stats.return_value = {"stats": {}, "last_update": 0.0}
    manager.get_share_stats.return_value = []
    manager.get_raffle_wins.return_value = []
    manager.get_xvb_standby.return_value = None
    manager.is_db_healthy.return_value = True
    manager.get_blocks.return_value = []
    manager.get_disk_growth.return_value = []
    manager.get_xvb_history.return_value = []
    manager.get_payouts.return_value = []
    manager.get_events.return_value = []
    manager.get_kv.return_value = None
    return manager


def _paired(data, manager, **kwargs):
    expected = adapter.python_call(data, manager, **kwargs)
    expected_calls = list(manager.method_calls)
    manager.reset_mock()
    actual = views.build_state(data, manager, **kwargs)
    actual_calls = list(manager.method_calls)
    assert actual == expected
    assert list(actual) == list(expected)
    assert actual_calls == expected_calls
    return expected, actual


def test_full_payload_keys_order_flags_window_and_collision():
    data = _data(sync_gate_monero_only=True, sync_status={"held": True})
    manager = _manager()
    snapshot = _snapshot()
    expected, actual = _paired(
        data,
        manager,
        range_arg="24h",
        window=(100.25, 200.75),
        avg_window="12h",
        history=[],
        metrics=_metrics(global_syncing=True, xvb_enabled=False),
        view_snapshot=snapshot,
    )
    assert list(actual) == EXPECTED_KEYS
    assert actual["host_ip"] == "stratum.example.com"
    assert actual["stratum_connected"] is snapshot["stratum"]["stratum_connected"]
    assert actual["page_title"] == "Pithead Dashboard - Syncing"
    assert actual["tari_gates_sync"] is False
    assert actual["window"] == {"from": 100.25, "to": 200.75}
    assert expected == actual


def test_raw_history_and_callback_results_keep_identity():
    history = RawValue()
    chart = RawValue()
    workers = RawValue()
    chart_inputs = []
    worker_inputs = []

    def chart_builder(*args, **kwargs):
        chart_inputs.append((args, kwargs))
        return chart

    def worker_builder(*args, **kwargs):
        worker_inputs.append((args, kwargs))
        return workers

    manager = _manager()
    _expected, actual = _paired(
        _data(workers=[{"name": "fixture"}]),
        manager,
        range_arg="all",
        window=None,
        history=history,
        metrics=_metrics(xvb_enabled=False),
        view_snapshot=_snapshot(),
        chart_builder=chart_builder,
        section_builders={"build_workers": worker_builder},
    )
    assert actual["chart"] is chart
    assert actual["workers"] is workers
    assert chart_inputs[0][0][0] is history
    assert chart_inputs[1][0][0] is history
    assert worker_inputs[0][0][0][0]["name"] == "fixture"
    assert worker_inputs[1][0][0][0]["name"] == "fixture"


def test_view_snapshot_blocks_live_provider_reads(monkeypatch):
    def fatal(*args, **kwargs):
        del args, kwargs
        raise AssertionError("live view provider used")

    for name in (
        "egress_posture_from_config",
        "topology_from_config",
        "host_display_addr",
        "dashboard_onion",
        "stratum_state",
        "resolve_version",
        "read_os_update_state",
    ):
        monkeypatch.setattr(views, name, fatal)
    manager = _manager()
    _paired(
        _data(),
        manager,
        range_arg="all",
        history=[],
        metrics=_metrics(xvb_enabled=False),
        view_snapshot=_snapshot(),
    )


def test_native_helper_failure_never_falls_back(monkeypatch):
    from mining_dashboard import go_state

    def fail(*args, **kwargs):
        del args, kwargs
        raise RuntimeError("native state unavailable")

    monkeypatch.setattr(go_state.go_channel, "call", fail)
    manager = _manager()
    try:
        views.build_state(
            _data(),
            manager,
            "all",
            history=[],
            metrics=_metrics(xvb_enabled=False),
            view_snapshot=_snapshot(),
        )
    except RuntimeError as error:
        assert str(error) == "native state unavailable"
    else:
        raise AssertionError("native failure fell back")
