from mining_dashboard import go_forecast, go_snapshot, go_state


def test_build_state_runs_full_section_pipeline(monkeypatch):
    metrics = type(
        "Metrics",
        (),
        {"mode": "p2pool", "xvb_enabled": False, "global_syncing": False, "workers_online": 2},
    )()
    pool = {
        "monero": {"db_size": 5},
        "stratum": {"ok": True},
        "pool": {"ok": True},
        "network": {"height": 1},
        "shares_window": 3,
    }
    sections = {
        "build_pool_network": lambda *_a, **_k: pool,
        "build_earnings": lambda *_a, **_k: {"coeff_day": 2, "xvb_day": 3},
        "build_earnings_vs_actual": lambda *_a, **_k: {"actual": True},
        "xvb_tempered_day": lambda value, realization: value,
        "build_badges": lambda *_a: [{"badge": "base"}],
        "_egress_badge": lambda summary: {"badge": summary["label"]},
        "build_xvb_calc": lambda *_a, **_k: {"calc": True},
    }

    def generic(*_args, **_kwargs):
        return {"built": True}

    for name in (
        "visible_update",
        "build_hashrate",
        "build_system",
        "build_host_resources",
        "build_sync",
        "build_cadence",
        "build_raffle_eligibility",
        "build_raffle_log",
        "build_tari",
        "build_workers",
        "build_energy",
        "build_proxy_summary",
        "build_share_stats",
        "_window_reject_pct",
        "build_blocks",
        "build_payouts",
        "build_disk_growth",
        "build_xvb_history",
    ):
        sections[name] = generic
    state = type(
        "State",
        (),
        {
            "get_history": lambda self: [{"ts": 1}],
            "get_share_stats": lambda self: {"accepted": 1},
            "get_raffle_wins": lambda self: [],
            "get_payouts": lambda self, chain: [],
            "is_db_healthy": lambda self: True,
            "get_disk_growth": lambda self: [],
            "get_xvb_standby": lambda self: None,
            "get_blocks": lambda self: [],
            "get_xvb_history": lambda self: [],
            "get_events": lambda self: [],
            "get_kv": lambda self, key: None,
        },
    )()
    snapshot = {
        "now": 10,
        "payout_confirm_enabled": False,
        "tari_payout_confirm_enabled": False,
        "egress": {"summary": {"label": "safe"}},
        "topology": {"nodes": []},
        "tari_required": False,
        "host_ip": "host",
        "host_addr": "host",
        "dashboard_onion": None,
        "stratum": {"endpoint": "stratum"},
        "version": {"text": "v"},
        "control_enabled": True,
        "os_update": None,
        "last_update": "now",
    }

    def assemble(values, slots, **kwargs):
        assert values[slots["build_pool_network"]] is pool
        assert kwargs["stratum"] == [["endpoint", slots["stratum.endpoint"]]]
        return {"assembled": True, "slot_count": len(values)}

    monkeypatch.setattr(go_state, "_assemble", assemble)
    result = go_state.build_state(
        {"workers": [], "system": {}},
        state,
        "day",
        window=(1, 2),
        metrics=metrics,
        section_builders=sections,
        view_snapshot=snapshot,
        chart_builder=lambda *_a, **_k: {"chart": True},
    )
    assert result["assembled"] is True
    assert result["slot_count"] > 30


def test_snapshot_collect_captures_settings_and_detaches_state(monkeypatch):
    wallet = {
        "payout_wallet_changed_ts": "19",
        "payout_wallet_prev8": "previous-wallet",
        "payout_wallet": "current-wallet",
    }
    state = type(
        "State",
        (),
        {
            "get_payouts": lambda self, chain: [{"chain": chain}],
            "get_kv": lambda self, key: wallet.get(key),
            "get_share_stats": lambda self: {"accepted": 1},
            "get_raffle_wins": lambda self: [],
            "is_db_healthy": lambda self: True,
            "get_xvb_stats": lambda self: {},
            "get_tiers": lambda self: {"one": 1},
            "get_xvb_round_stats": lambda self: {},
            "get_xvb_reward_estimates": lambda self: {},
            "get_disk_growth": lambda self: [],
            "get_xvb_standby": lambda self: None,
            "get_blocks": lambda self: [],
            "get_xvb_history": lambda self: [],
            "get_events": lambda self: [],
        },
    )()
    monkeypatch.setattr(go_snapshot.time, "time", lambda: 20)
    monkeypatch.setattr(go_snapshot.config, "PAYOUT_CONFIRM_ENABLED", True)
    monkeypatch.setattr(go_snapshot.config, "TARI_PAYOUT_CONFIRM_ENABLED", True)
    monkeypatch.setattr(go_snapshot, "host_display_addr", lambda value: "display")
    monkeypatch.setattr(go_snapshot, "dashboard_onion", lambda: "onion")
    monkeypatch.setattr(go_snapshot, "stratum_state", lambda: {"port": 1})
    monkeypatch.setattr(go_snapshot, "resolve_version", lambda: {"text": "v"})
    monkeypatch.setattr(go_snapshot, "egress_posture_from_config", lambda: {"summary": {}})
    monkeypatch.setattr(go_snapshot, "topology_from_config", lambda: {"nodes": []})
    monkeypatch.setattr(go_forecast, "settings", lambda: {"prior": []})
    monkeypatch.setattr(go_forecast, "tiers", lambda values: [{"tier": values}])
    monkeypatch.setattr(go_snapshot.config, "current_worker_endpoints", lambda: [])
    snapshot = go_snapshot.collect({"timestamp": 2}, state)
    assert snapshot["settings"]["now"] == 20
    assert snapshot["settings"]["host_addr"] == "display"
    assert snapshot["settings"]["forecast"] == {"prior": []}
    assert snapshot["settings"]["forecast_tiers"] == [{"tier": {"one": 1}}]
    assert snapshot["storage"]["payouts"]["monero"] == [{"chain": "monero"}]
    assert snapshot["storage"]["kv"]["payout_wallet_prev8"] == "previous"
    snapshot["storage"]["share_stats"]["accepted"] = 9
    assert state.get_share_stats()["accepted"] == 1


def test_frozen_state_exposes_all_detached_storage_views():
    storage = {
        "share_stats": {"accepted": 1},
        "raffle_wins": [{"ts": 1}, {"ts": 3}],
        "payouts": {"monero": [{"ts": 1}], "tari": [{"ts": 2}]},
        "db_healthy": 1,
        "xvb_stats": {"a": 1},
        "tiers": {"tier": 1},
        "xvb_round_stats": {"round": 1},
        "xvb_reward_estimates": {"reward": 1},
        "disk_growth": [{"ts": 1}, {"ts": 4}],
        "xvb_standby": {"active": True},
        "blocks": [{"ts": 2}],
        "xvb_history": [{"ts": 3}],
        "events": [{"event": 1}],
        "kv": {"payout_wallet": "wallet"},
    }
    state = go_snapshot.FrozenState({"storage": storage})
    assert state.get_raffle_wins(2) == [{"ts": 3}]
    assert state.get_payouts() == [{"ts": 2}, {"ts": 1}]
    assert state.get_payouts("missing") == []
    assert state.is_db_healthy() is True
    assert state.get_xvb_stats() == {"a": 1}
    assert state.get_tiers() == {"tier": 1}
    assert state.get_xvb_round_stats() == {"round": 1}
    assert state.get_xvb_reward_estimates() == {"reward": 1}
    assert state.get_disk_growth(2) == [{"ts": 4}]
    assert state.get_xvb_standby() == {"active": True}
    assert state.get_blocks() == [{"ts": 2}]
    assert state.get_xvb_history() == [{"ts": 3}]
    assert state.get_events() == [{"event": 1}]
    assert state.get_kv("payout_wallet") == "wallet"
