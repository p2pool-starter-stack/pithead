from dataclasses import asdict, replace

import pytest

from mining_dashboard import go_bridge, go_snapshot
from mining_dashboard.config import config
from mining_dashboard.service.metrics import build_metrics


def require(condition, message):
    if not condition:
        raise AssertionError(message)


class State:
    def __init__(self, history):
        self.history = history
        self.fail = False
        self.calls = []

    def read(self, name, value):
        if self.fail:
            raise AssertionError(f"live read during compact finish: {name}")
        self.calls.append(name)
        return value

    def get_history(self):
        return self.read("history", self.history)

    def get_share_stats(self):
        return self.read("share_stats", [])

    def get_raffle_wins(self, since=0.0):
        return self.read("raffle_wins", [])

    def get_payouts(self, chain=None):
        return self.read(f"payouts:{chain}", [])

    def is_db_healthy(self):
        return self.read("db_healthy", True)

    def get_xvb_stats(self):
        return self.read(
            "xvb_stats",
            {"current_mode": "P2POOL", "avg_1h": 0, "avg_24h": 0},
        )

    def get_tiers(self):
        return self.read("tiers", {})

    def get_xvb_round_stats(self):
        return self.read("xvb_round_stats", {"stats": {}, "last_update": 0})

    def get_xvb_reward_estimates(self):
        return self.read("xvb_reward_estimates", {"estimates": {}, "last_update": 0})

    def get_disk_growth(self, since=0.0):
        return self.read("disk_growth", [])

    def get_xvb_standby(self):
        return self.read("xvb_standby", {"generation": "old"})

    def get_blocks(self, since=0.0):
        return self.read("blocks", [])

    def get_xvb_history(self, since=0.0):
        return self.read("xvb_history", [])

    def get_events(self):
        return self.read("events", [])

    def get_kv(self, key):
        return self.read(f"kv:{key}", "0")


class Request:
    def __init__(self, app, query=None, payload=None):
        self.app = app
        self.query = query or {}
        self.payload = payload

    def clone(self, **_kwargs):
        return self

    async def json(self):
        return self.payload


@pytest.mark.asyncio
async def test_compact_state_freezes_one_clock_and_generation(monkeypatch):
    old_clock = 3_000_000.0
    monkeypatch.setattr(config, "PAYOUT_CONFIRM_ENABLED", False)
    monkeypatch.setattr(config, "TARI_PAYOUT_CONFIRM_ENABLED", False)
    monkeypatch.setattr(config, "DASHBOARD_CONTROL_ENABLED", True)
    monkeypatch.setattr(config, "current_worker_endpoints", lambda: [])
    monkeypatch.setattr(go_snapshot.time, "time", lambda: old_clock)
    history = [
        {
            "t": "old",
            "timestamp": old_clock - 30,
            "v": 7,
            "v_p2pool": 7,
            "v_xvb": 0,
        }
    ]
    manager = State(history)
    data = {
        "shares": [],
        "workers": [],
        "global_sync": False,
        "total_live_h15": 7,
        "monero_sync": {"percent": 100, "current": 10, "target": 10},
        "tari_sync": {"percent": 100, "current": 10, "target": 10},
        "timestamp": old_clock,
        "sync_status": "old",
    }
    captured = go_bridge._state(
        Request({"latest_data": data, "state_manager": manager}, {"range": "1h"}),
        compact=True,
    )
    frozen = go_snapshot.FrozenState(captured["snapshot"])
    averages = captured["domain"]["averages"]
    metric_values = replace(
        build_metrics(captured["domain"]["latest_data"], frozen, []),
        p2pool_1h=averages["p2pool_1h"],
        p2pool_24h=averages["p2pool_24h"],
        p2pool_30d=averages["p2pool_30d"],
        xvb_routed_1h=averages["xvb_routed_1h"],
        xvb_routed_24h=averages["xvb_routed_24h"],
    )
    prepared = {
        "latest_data": captured["domain"]["latest_data"],
        "metrics": asdict(metric_values),
        "sections": {},
        "snapshot": captured["snapshot"],
        "compact_chart": True,
    }
    calls = list(manager.calls)
    data["sync_status"] = "new"
    history[0]["v_p2pool"] = 99
    manager.fail = True
    monkeypatch.setattr(go_snapshot.time, "time", lambda: old_clock + 7200)

    result = await go_bridge._finish_state(
        Request({"state_manager": manager}, {"range": "1h"}, prepared)
    )

    require("history" not in captured["domain"], "compact domain included history")
    require(captured["domain"]["now"] == old_clock, "domain clock changed")
    require(captured["domain"]["averages"]["p2pool_1h"] == 7, "average changed")
    require(captured["chart"]["history"][0]["v_p2pool"] == 7, "chart changed")
    require(captured["chart"]["duration"] == 3600, "chart duration changed")
    require(result["state"]["sync_status"] == "old", "state generation changed")
    require(
        result["state"]["xvb_standby"] == {"generation": "old"},
        "storage generation changed",
    )
    require("history" not in result["chart"], "POST response included history")
    require(manager.calls == calls, "finish read live storage")
