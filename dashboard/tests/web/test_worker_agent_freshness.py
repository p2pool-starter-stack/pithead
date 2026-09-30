from datetime import UTC, datetime, timedelta

from mining_dashboard.service.storage_service import StateManager
from mining_dashboard.web.views.infra_views import build_workers
from mining_dashboard.web.views.worker_detail import build_worker_detail


def _worker(rigforge):
    return {
        "name": "r",
        "ip": "1.1.1.1",
        "status": "online",
        "active_pool": "3333",
        "accepted": 50,
        "rigforge": rigforge,
    }


def _fresh(**values):
    return {"generated_at": datetime.now(UTC).strftime("%Y-%m-%dT%H:%M:%SZ"), **values}


def test_proxy_online_wins_over_fresh_agent_miner_down():
    row = build_workers([_worker(_fresh(version="1.7.0", miner_down=True))])[0]
    assert row["status"] == "online"
    assert row["rigforge"]["chips"][0]["text"] == "agent reports miner down"
    assert row["rigforge"]["chips"][0]["variant"] == "warn"


def test_worker_inspect_also_keeps_proxy_online_authoritative(monkeypatch):
    from mining_dashboard.web.views import views

    monkeypatch.setattr(views.config, "DASHBOARD_WORKERS", [])
    state = StateManager(db_path=":memory:")
    report = _fresh(version="1.7.0", miner_down=True)
    try:
        detail = build_worker_detail(
            "r",
            {"workers": [_worker(report)], "timestamp": 1790711070.25},
            state,
        )
    finally:
        state.close()
    assert detail["rigforge"]["chips"][0]["text"] == "agent reports miner down"
    assert detail["rigforge"]["chips"][0]["variant"] == "warn"
    assert detail["rigforge"]["generated_at"] == report["generated_at"]
    assert detail["rigforge"]["stale"] is False
    assert detail["snapshot_at"] == 1790711070.25


def test_stale_agent_fields_are_hidden_and_cannot_drive_update_badge():
    agent = {
        "version": "1.7.0",
        "generated_at": (datetime.now(UTC) - timedelta(hours=1)).strftime("%Y-%m-%dT%H:%M:%SZ"),
        "miner_down": True,
        "stale": True,
        "age_sec": 3600,
        "watchdog": {"enabled": True, "temp_c": 99},
    }
    row = build_workers([_worker(agent)], {"tag": "v2.0.0", "url": "https://h/v2.0.0"})[0]
    assert row["status"] == "online"
    assert row["rigforge"]["version"] is None
    assert row["rigforge"]["stale"] is True
    assert row["rigforge"]["generated_at"] == agent["generated_at"]
    assert [c["text"] for c in row["rigforge"]["chips"]] == ["agent stale for 1h 0m"]
    assert row["rigforge_update"] is None
