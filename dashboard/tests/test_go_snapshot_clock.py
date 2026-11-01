from mining_dashboard import go_bridge, go_snapshot
from mining_dashboard.config import config


class State:
    def get_history(self):
        return []

    def get_share_stats(self):
        return []

    def get_raffle_wins(self):
        return []

    def is_db_healthy(self):
        return True

    def get_xvb_stats(self):
        return {}

    def get_tiers(self):
        return {}

    def get_xvb_round_stats(self):
        return {}

    def get_xvb_reward_estimates(self):
        return {}

    def get_disk_growth(self):
        return []

    def get_xvb_standby(self):
        return None

    def get_blocks(self):
        return []

    def get_xvb_history(self):
        return []

    def get_events(self):
        return []

    def get_kv(self, _key):
        return "0"


class Request:
    def __init__(self):
        self.app = {"latest_data": {"timestamp": 1}, "state_manager": State()}


def test_state_uses_one_clock_snapshot(monkeypatch):
    monkeypatch.setattr(config, "PAYOUT_CONFIRM_ENABLED", False)
    monkeypatch.setattr(config, "TARI_PAYOUT_CONFIRM_ENABLED", False)
    monkeypatch.setattr(config, "current_worker_endpoints", lambda: [])
    ticks = iter((100.0, 200.0))
    calls = []

    def clock():
        value = next(ticks)
        calls.append(value)
        return value

    monkeypatch.setattr(go_snapshot.time, "time", clock)
    result = go_bridge._state(Request())

    assert result["snapshot"]["settings"]["now"] == 100.0
    assert result["domain"]["now"] == 100.0
    assert calls == [100.0]
