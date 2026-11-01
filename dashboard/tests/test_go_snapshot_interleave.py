import time
from dataclasses import asdict

import pytest

from mining_dashboard import go_bridge, go_snapshot
from mining_dashboard.config import config
from mining_dashboard.helper import utils
from mining_dashboard.service.metrics import build_metrics


class GenerationState:
    def __init__(self):
        self.fail = False
        self.calls = []

    def read(self, name, value):
        if self.fail:
            raise AssertionError(f"live storage read during finish: {name}")
        self.calls.append(name)
        return value

    def get_history(self):
        return self.read("history", [])

    def get_share_stats(self):
        return self.read("share_stats", [{"ts": 1, "accepted": 2, "rejected": 0}])

    def get_raffle_wins(self, since=0.0):
        return self.read("raffle_wins", [])

    def get_payouts(self, chain=None):
        return self.read(
            f"payouts:{chain}",
            [{"chain": chain, "txid": "old", "height": 1, "ts": 1, "amount_atomic": 1}],
        )

    def is_db_healthy(self):
        return self.read("db_healthy", True)

    def get_xvb_stats(self):
        return self.read("xvb_stats", {"current_mode": "P2POOL", "avg_1h": 0, "avg_24h": 0})

    def get_tiers(self):
        return self.read("tiers", {"donor": 1.0})

    def get_xvb_round_stats(self):
        return self.read(
            "xvb_round_stats",
            {
                "stats": {"types": {"donor": {"rounds": 1, "players_avg": 1}}, "span_days": 1},
                "last_update": time.time() - utils.XVB_STATS_STALE_AFTER_S + 1,
            },
        )

    def get_xvb_reward_estimates(self):
        return self.read(
            "xvb_reward_estimates",
            {
                "estimates": {"donor": 1.0},
                "last_update": time.time() - utils.XVB_STATS_STALE_AFTER_S + 1,
            },
        )

    def get_disk_growth(self, since=0.0):
        return self.read("disk_growth", [])

    def get_xvb_standby(self):
        return self.read("xvb_standby", {"generation": "old"})

    def get_blocks(self, since=0.0):
        return self.read("blocks", [{"ts": 1, "height": 7, "difficulty": 8}])

    def get_xvb_history(self, since=0.0):
        return self.read("xvb_history", [])

    def get_events(self):
        return self.read("events", [{"ts": 1, "type": "old", "detail": "old"}])

    def get_kv(self, key):
        values = {
            "payout_wallet_changed_ts": str(time.time()),
            "payout_wallet_prev8": "old-prev-secret",
            "payout_wallet": "old-wallet-secret",
        }
        return self.read(f"kv:{key}", values[key])


class Request:
    def __init__(self, app, payload=None):
        self.app = app
        self.query = {}
        self.payload = payload

    def clone(self, **_kwargs):
        return self

    async def json(self):
        return self.payload


def test_snapshot_preserves_disabled_payout_and_stale_wallet_gates(monkeypatch):
    monkeypatch.setattr(config, "PAYOUT_CONFIRM_ENABLED", False)
    monkeypatch.setattr(config, "TARI_PAYOUT_CONFIRM_ENABLED", False)
    monkeypatch.setattr(config, "current_worker_endpoints", lambda: [])
    manager = GenerationState()

    def get_kv(key):
        if key != "payout_wallet_changed_ts":
            raise AssertionError(f"unexpected wallet read: {key}")
        return manager.read(f"kv:{key}", "0")

    manager.get_kv = get_kv
    snapshot = go_snapshot.collect({}, manager)

    assert snapshot["storage"]["payouts"] == {"monero": [], "tari": []}
    assert snapshot["storage"]["kv"] == {"payout_wallet_changed_ts": "0"}
    assert not any(call.startswith("payouts:") for call in manager.calls)


@pytest.mark.asyncio
async def test_finish_state_uses_one_frozen_generation(monkeypatch):
    monkeypatch.setattr(config, "PAYOUT_CONFIRM_ENABLED", True)
    monkeypatch.setattr(config, "TARI_PAYOUT_CONFIRM_ENABLED", True)
    monkeypatch.setattr(config, "TARI_REQUIRED", True)
    monkeypatch.setattr(config, "DASHBOARD_CONTROL_ENABLED", True)
    monkeypatch.setattr(config, "HOST_IP", "127.0.0.1")
    monkeypatch.setattr(
        config,
        "DASHBOARD_ENERGY",
        {
            "cost_per_kwh": 1,
            "xmr_price": 0,
            "tari_price": 0,
            "currency": "OLD",
            "price_feed": False,
        },
    )
    monkeypatch.setattr(
        config, "current_worker_endpoints", lambda: [{"name": "old-worker", "watts": 123}]
    )
    manager = GenerationState()
    data = {
        "shares": [],
        "workers": [],
        "global_sync": False,
        "total_live_h15": 0,
        "monero_sync": {"percent": 100, "current": 10, "target": 10},
        "tari_sync": {"percent": 50, "current": 5, "target": 10},
        "timestamp": 1,
        "sync_status": "old",
    }
    first = go_bridge._state(Request({"latest_data": data, "state_manager": manager}))
    snapshot = first["snapshot"]
    frozen = go_snapshot.FrozenState(snapshot)
    prepared = {
        "latest_data": first["domain"]["latest_data"],
        "history": first["domain"]["history"],
        "metrics": asdict(
            build_metrics(first["domain"]["latest_data"], frozen, first["domain"]["history"])
        ),
        "sections": {},
        "snapshot": snapshot,
    }
    data["sync_status"] = "new"
    manager.fail = True
    monkeypatch.setattr(config, "PAYOUT_CONFIRM_ENABLED", False)
    monkeypatch.setattr(config, "TARI_PAYOUT_CONFIRM_ENABLED", False)
    monkeypatch.setattr(config, "TARI_REQUIRED", False)
    monkeypatch.setattr(config, "DASHBOARD_CONTROL_ENABLED", False)
    monkeypatch.setattr(config, "HOST_IP", "192.0.2.1")
    monkeypatch.setattr(
        config,
        "DASHBOARD_ENERGY",
        {
            "cost_per_kwh": 9,
            "xmr_price": 0,
            "tari_price": 0,
            "currency": "NEW",
            "price_feed": True,
        },
    )
    monkeypatch.setattr(
        config, "current_worker_endpoints", lambda: [{"name": "new-worker", "watts": 999}]
    )
    monkeypatch.setattr(
        time,
        "time",
        lambda: snapshot["settings"]["now"] + utils.XVB_STATS_STALE_AFTER_S + 10,
    )
    result = await go_bridge._finish_state(Request({"state_manager": manager}, prepared))

    assert result["state"]["sync_status"] == "old"
    assert result["state"]["xvb_standby"] == {"generation": "old"}
    assert result["state"]["db_healthy"] is True
    assert result["state"]["control_enabled"] is True
    assert result["state"]["tari_gates_sync"] is True
    assert result["state"]["host_ip"] == "127.0.0.1"
    assert result["chart"]["events"][0]["type"] == "old"
    assert result["series"]["blocks"]["args"][0][0]["height"] == 7
    assert result["presentation"]["energy"]["args"][2]["currency"] == "OLD"
    assert result["presentation"]["energy"]["args"][3][0]["name"] == "old-worker"
    assert result["state"]["xvb_calc"]["estimates_stale"] is False
    assert snapshot["storage"]["kv"]["payout_wallet_prev8"] == "old-prev"
    assert snapshot["storage"]["kv"]["payout_wallet"] == "old-wall"
    assert manager.calls == [
        "history",
        "payouts:monero",
        "payouts:tari",
        "kv:payout_wallet_changed_ts",
        "kv:payout_wallet_prev8",
        "kv:payout_wallet",
        "share_stats",
        "raffle_wins",
        "db_healthy",
        "xvb_stats",
        "tiers",
        "xvb_round_stats",
        "xvb_reward_estimates",
        "disk_growth",
        "xvb_standby",
        "blocks",
        "xvb_history",
        "events",
    ]
