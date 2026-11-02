import asyncio

import pytest

from mining_dashboard import (
    go_domain,
    go_earnings,
    go_editor,
    go_fleet,
    go_forecast,
    go_overview,
    go_snapshot,
    go_state,
    go_views,
)
from mining_dashboard.go_state_executor import StateExecutor


def _pairs(stratum=()):
    keys = list(go_state.STATE_KEYS) + [key for key, _ in stratum]
    return [[key, {"ref": 0}] for key in keys]


def test_resolve_preserves_references_and_rejects_bad_indices():
    value = {"nested": [{"ref": 0}, 3]}
    marker = object()
    assert go_state._resolve(value, [marker])["nested"][0] is marker
    with pytest.raises(RuntimeError, match="invalid reference"):
        go_state._resolve({"ref": True}, [marker])
    with pytest.raises(RuntimeError, match="invalid reference"):
        go_state._resolve({"ref": 2}, [marker])


def test_assemble_sends_contract_and_preserves_slot_identity(monkeypatch):
    marker = {"opaque": object()}
    seen = {}

    def call(helper, payload):
        seen.update(helper=helper, payload=payload)
        return _pairs()

    monkeypatch.setattr(go_state.go_channel, "call", call)
    result = go_state._assemble(
        [marker],
        {"metrics": 0},
        syncing=True,
        tari_required=False,
        monero_only=False,
        stratum=[],
        window=None,
    )
    assert seen["helper"] == "state"
    assert seen["payload"]["input"]["slot_count"] == 1
    assert all(value is marker for value in result.values())


@pytest.mark.parametrize("reply", [None, [["page_title"]], [[1, {"ref": 0}]], []])
def test_assemble_rejects_malformed_or_incomplete_replies(monkeypatch, reply):
    monkeypatch.setattr(go_state.go_channel, "call", lambda *_args: reply)
    with pytest.raises(RuntimeError):
        go_state._assemble(
            [object()],
            {},
            syncing=False,
            tari_required=False,
            monero_only=False,
            stratum=[],
            window=None,
        )


@pytest.mark.asyncio
async def test_state_executor_runs_releases_slots_and_closes():
    executor = StateExecutor()
    assert await executor.run(lambda left, right: left + right, 2, 3) == 5
    await executor.close()


@pytest.mark.asyncio
async def test_state_executor_rejects_when_all_slots_are_held():
    executor = StateExecutor()
    for _ in range(4):
        assert executor._slots.acquire(blocking=False)
    try:
        with pytest.raises(RuntimeError, match="busy"):
            await executor.run(lambda: None)
    finally:
        for _ in range(4):
            executor._slots.release()
        await executor.close()


def test_state_executor_releases_slot_when_submit_fails(monkeypatch):
    executor = StateExecutor()
    monkeypatch.setattr(
        executor._executor, "submit", lambda *_a, **_k: (_ for _ in ()).throw(OSError())
    )
    with pytest.raises(OSError):
        asyncio.run(executor.run(lambda: None))
    assert executor._slots.acquire(blocking=False)
    executor._slots.release()
    asyncio.run(executor.close())


def test_editor_shapes_paths_and_audit_selection(monkeypatch):
    assert go_editor._shape({"flag": True, "text": "secret", "rows": [1]}) == {
        "flag": True,
        "text": None,
        "rows": [],
    }
    monkeypatch.setattr(go_editor, "_call", lambda operation, **kwargs: ["a", "b"])
    assert list(go_editor.leaf_paths({"a": True})) == ["a", "b"]
    monkeypatch.setattr(go_editor, "_call", lambda operation, **kwargs: [1])
    with pytest.raises(RuntimeError, match="invalid paths"):
        list(go_editor.leaf_paths({}))

    entries = [
        {"action": "commit", "status": "applied", "id": "one", "opaque": object()},
        {"action": "other", "status": "failed"},
    ]
    monkeypatch.setattr(go_editor, "_call", lambda operation, **kwargs: 0)
    assert go_editor.last_apply_state(entries) == {"status": "applied", "id": "one"}
    monkeypatch.setattr(go_editor, "_call", lambda operation, **kwargs: 2)
    with pytest.raises(RuntimeError, match="invalid audit index"):
        go_editor.last_apply_state(entries)


def test_editor_version_metadata_mutates_original(monkeypatch):
    from mining_dashboard.service import config_operations

    monkeypatch.setattr(go_editor, "VERSION_PROVIDER", config_operations.parse_semver)
    monkeypatch.setattr(
        go_editor,
        "_call",
        lambda operation, **kwargs: {"pop_version": True, "newer": False},
    )
    cfg = {"config_version": "old", "other": 1}
    result = go_editor.config_version_metadata(cfg, {"config_version": "new"})
    assert result is cfg
    assert cfg == {"other": 1, "_config_version_newer": False}
    monkeypatch.setattr(go_editor, "_call", lambda *_a, **_kw: {"newer": False})
    with pytest.raises(RuntimeError, match="invalid version result"):
        go_editor.config_version_metadata({}, {})


def test_domain_collect_compact_and_restore(monkeypatch):
    from mining_dashboard.service import metrics

    state = type(
        "State",
        (),
        {
            "get_history": lambda self: [1],
            "get_xvb_stats": lambda self: {"wins": 1},
            "get_tiers": lambda self: {"one": 10},
        },
    )()
    monkeypatch.setattr(metrics, "_avg_p2pool_at", lambda history, period, now: period)
    monkeypatch.setattr(metrics, "_avg_xvb_at", lambda history, period, now: period)
    result = go_domain.collect({"height": 1}, state, now=5, compact=True)
    assert result["latest_data"] == {"height": 1}
    assert result["tiers"] == [{"name": "one", "threshold": 10}]
    assert result["averages"]["p2pool_1h"] == 3600
    assert "history" not in result

    monkeypatch.setattr(metrics, "SyncMetric", lambda **values: ("sync", values))
    monkeypatch.setattr(metrics, "Metrics", lambda **values: values)
    restored = go_domain.restore({"monero": {"percent": 100}, "tari": {"percent": 0}})
    assert restored["monero"] == ("sync", {"percent": 100})


def test_view_and_fleet_builders_capture_json_safe_requests():
    captured = {}
    builders = go_views.builders({}, captured, {"now": 7, "zone": "UTC"})
    builders["build_share_stats"](({"ts": 1},), "all", None)
    assert captured["share_stats"]["operation"] == "build_share_stats"
    assert captured["share_stats"]["args"][0] == [{"ts": 1}]

    captured = {}
    fleet = go_fleet.builders(
        captured,
        {
            "now": 8,
            "worker_endpoints": [{"name": "one", "watts": 10}],
            "energy_config": {"enabled": True},
            "resource_max_age": 9,
        },
    )
    fleet["build_energy"](({"name": "one"},), {"price": 1})
    fleet["build_host_resources"]({"ram": float("inf")}, ((1, 2),))
    assert captured["energy"]["args"][-1] == [{"name": "one", "watts": 10}]
    assert captured["host_resources"]["args"][0]["ram"] == {"__pithead_nonfinite__": "inf"}


def test_overview_earnings_and_forecast_builders_capture_and_return_values():
    captured = {}
    overview = go_overview.builders(
        captured,
        {"now": 3, "zone": "UTC", "badge_settings": {"disk": 1}, "version": {"text": "v1"}},
    )
    monero = {"state": "ready"}
    pool = overview["build_pool_network"]({}, object(), lambda *_args: monero)
    assert pool["monero"] is monero
    assert overview["build_badges"]({}, object(), "ok") == []
    overview["visible_update"]({"version": "v2"})
    assert captured["update"]["args"][-1] == "v1"

    prepared = dict.fromkeys(
        {
            "available",
            "p2pool_hr",
            "p2pool_hr_str",
            "coeff_day",
            "tari_available",
            "tari_coeff_day",
            "tari_difficulty",
            "tari_reward",
            "xvb_day",
            "pool_difficulty",
            "block_reward",
            "disclaimer",
            "confirmed",
            "tari_confirmed",
        }
    )
    earnings = go_earnings.builders(prepared, captured, {"now": 4, "zone": "UTC"})
    result = earnings["build_earnings"]({}, object(), xvb_day=2)
    assert result["xvb_day"] == 2
    earnings["build_earnings_vs_actual"](object(), result, [])
    assert captured["earnings_summary"]["operation"] == "build_earnings_vs_actual"

    forecast_values = {
        "current_key": "one",
        "forecast_key": "two",
        "xvb_day": 1,
        "expected_wins_day": 2,
        "realization": 3,
        "tempered_day": 4,
        "xvb_calc": {"value": 5},
    }
    forecast = go_forecast.builders(forecast_values)
    assert forecast["xvb_realization"]() == 3
    with pytest.raises(RuntimeError, match="forecast unavailable"):
        go_forecast.builders({})


def test_frozen_state_copies_filters_and_sorts_storage():
    storage = {
        "share_stats": {"accepted": 1},
        "raffle_wins": [{"ts": 1}, {"ts": 3}],
        "payouts": {"monero": [{"ts": 2}], "tari": [{"ts": 4}]},
        "db_healthy": 1,
        "xvb_stats": {},
        "tiers": {},
        "xvb_round_stats": {},
        "xvb_reward_estimates": {},
        "disk_growth": [{"ts": 1}, {"ts": 5}],
        "xvb_standby": None,
        "blocks": [{"ts": 2}],
        "xvb_history": [{"ts": 6}],
        "events": [],
        "kv": {"payout_wallet": "wallet"},
    }
    state = go_snapshot.FrozenState({"storage": storage})
    assert state.get_payouts() == [{"ts": 4}, {"ts": 2}]
    assert state.get_raffle_wins(2) == [{"ts": 3}]
    assert state.get_disk_growth(5) == [{"ts": 5}]
    assert state.get_kv("payout_wallet") == "wallet"
    with pytest.raises(KeyError):
        state.get_kv("other")
    copied = state.get_share_stats()
    copied["accepted"] = 9
    assert state.get_share_stats()["accepted"] == 1
