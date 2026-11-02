import copy
import os

import dashboard_worker_detail_plugin as adapter
import pytest

# ruff: noqa: S101

pytestmark = pytest.mark.skipif(
    os.environ.get("PITHEAD_IMPL") != "go", reason="Go dashboard parity only"
)

NOW = 1_800_000_000.0
META = {
    "revision": "0123456789abcdef",
    "changed_at": "2027-01-15T08:00:00Z",
    "source": "control",
    "last_change_id": "change-1",
}


class State:
    def __init__(self, **values):
        self.values = values

    def _get(self, name, default):
        return copy.deepcopy(self.values.get(name, default))

    def get_worker_config_history(self, worker, limit=50):
        del worker
        return (
            self._get("history", [])[:limit] if self.values.get("history", []) is not None else None
        )

    def get_worker_hashrate_by_config(self, worker):
        del worker
        return self._get("by_config", [])

    def get_worker_config_change(self, worker, change_id):
        del worker, change_id
        return self._get("matched", {})

    def get_last_applied_worker_config(self, worker):
        del worker
        return self._get("last_applied", {})

    def get_worker_revision_drift(self, worker, revision):
        del worker, revision
        return self._get("revision_drift", None)

    def get_worker_history(self, name):
        del name
        return self._get("samples", [])


def paired(operation, *args, **kwargs):
    expected = adapter.python_call(operation, *copy.deepcopy(args), **copy.deepcopy(kwargs))
    actual = adapter.NATIVES[operation](*copy.deepcopy(args), **copy.deepcopy(kwargs))
    return expected, actual


@pytest.mark.parametrize(
    ("meta", "known", "status", "unread", "verdict"),
    [
        (None, False, None, False, None),
        (META, False, None, False, "elsewhere"),
        (META, True, "applied", False, "here"),
        (META, True, "rolled_back", False, "reverted"),
        (META, True, "accepted", False, "unconfirmed"),
        (META, True, "applied", True, "unread"),
        ({**META, "source": "local"}, False, None, False, "rig"),
        ({**META, "source": "restore"}, False, None, False, "restored"),
        ({**META, "source": None}, False, None, False, "unrecorded"),
    ],
)
def test_config_origin_matches(meta, known, status, unread, verdict):
    assert paired("config_origin", meta, known, status, unread) == (verdict, verdict)


@pytest.mark.parametrize(
    ("history", "expected"),
    [
        ([], False),
        ([{"type": "upgrade", "status": "running"}], False),
        ([{"type": "upgrade"}, {"status": "accepted"}], True),
        ([{"status": "applied"}, {"status": "running"}], False),
        ([{"status": "running"}], True),
    ],
)
def test_unsettled_apply_uses_newest_apply(history, expected):
    assert paired("_has_unsettled_apply", history) == (expected, expected)


def test_config_drift_canonicalizes_types_and_strips_credentials():
    applied = {
        "DONATION": "3",
        "watchdog_interval_min": 4,
        "autotune": 7,
        "max_temp_c": None,
        "pools": [{"url": "pool.example.com:3333", "pass": "hidden"}],
    }
    rig = {
        "DONATION": 3,
        "watchdog_interval_min": 5,
        "autotune": "7",
        "max_temp_c": 80,
        "pools": [{"url": "pool.example.com:3333", "pass": {"__secret__": True}}],
    }
    expected, actual = paired("config_drift", applied, rig)
    assert actual == expected
    assert [row["key"] for row in actual] == ["max_temp_c", "watchdog_interval_min"]
    assert "hidden" not in repr(actual)


def test_config_drift_preserves_unknown_missing_and_inflight_contracts():
    assert paired("config_drift", {"DONATION": 4}, {}, False) == ([], [])
    assert paired("config_drift", {"DONATION": 4}, {"DONATION": 5}, True) == (None, None)
    assert paired("config_drift", None, {"DONATION": 5}, False) == (None, None)
    assert paired("config_drift", {"DONATION": True}, {"DONATION": 1}, False)[1]


def test_hashrate_history_window_and_markers_match():
    state = State(
        samples=[
            {"ts": 1000.0, "name": "rig", "h15": 1000.0},
            {"ts": 2000.0, "name": "rig", "h15": 2000.0},
            {"ts": 3000.0, "name": "rig", "h15": 3000.0},
        ],
        history=[
            {"ts": 1500.0, "status": "applied", "changes": {"DONATION": 2}},
            {
                "ts": 2500.0,
                "status": "failed",
                "type": "upgrade",
                "changes": {"version": "v2.0.0"},
                "reason": "rejected",
            },
        ],
    )
    expected, actual = paired(
        "build_worker_hashrate_history", state, "rig", "all", (1900.0, 3100.0)
    )
    assert actual == expected
    assert actual["hashrate"] == [
        {"x": 2_000_000, "y": 2000.0},
        {"x": 3_000_000, "y": 3000.0},
    ]
    assert actual["markers"][0]["type"] == "upgrade"


def _detail_state(**values):
    defaults = {
        "history": [
            {
                "ts": 2000.0,
                "change_id": "change-1",
                "status": "applied",
                "changes": {"DONATION": 3},
                "reason": None,
            }
        ],
        "by_config": [
            {
                "ts": 2000.0,
                "change_id": "change-1",
                "avg_h15": 2000.0,
                "min_h15": 1000.0,
                "max_h15": 3000.0,
                "sample_count": 2,
            }
        ],
        "matched": {"status": "applied"},
        "last_applied": {"DONATION": "3"},
        "samples": [{"ts": 2100.0, "name": "rig", "h15": 2200.0}],
    }
    return State(**{**defaults, **values})


def _worker():
    return {
        "name": "rig",
        "ip": "192.0.2.44",
        "status": "online",
        "h60": 5100.0,
        "rigforge": {
            "config_meta": META,
            "config": {"DONATION": 3},
        },
    }


def test_full_detail_matches_editable_observed_ip_and_formatted_history(monkeypatch):
    from mining_dashboard.config import config

    monkeypatch.setattr(
        config,
        "DASHBOARD_WORKERS",
        [{"name": "rig", "host": "rig.example.com", "control_port": 8082}],
    )
    monkeypatch.setattr(config, "DASHBOARD_CONTROL_ENABLED", True)
    data = {"timestamp": NOW, "workers": [_worker()], "rigforge_release": None}
    expected, actual = paired("build_worker_detail", "rig", data, _detail_state())
    assert actual == expected
    assert actual["found"] is actual["editable"] is True
    assert actual["ip"] == "192.0.2.44"
    assert actual["config_origin"] == "here"
    assert actual["config_drift"] == []
    assert actual["history"][0]["applied_at"]
    assert actual["hashrate_by_config"][0]["avg_h15"] == "2.00 kH/s"


@pytest.mark.parametrize(
    ("state", "origin", "drift"),
    [
        (_detail_state(matched={}), "elsewhere", []),
        (_detail_state(matched=None), "unread", []),
        (
            _detail_state(
                history=[{"ts": 2000.0, "status": "accepted", "changes": {"DONATION": 4}}]
            ),
            "here",
            None,
        ),
    ],
)
def test_full_detail_known_miss_unread_and_inflight_match(monkeypatch, state, origin, drift):
    from mining_dashboard.config import config

    monkeypatch.setattr(config, "DASHBOARD_WORKERS", [])
    data = {"timestamp": NOW, "workers": [_worker()]}
    expected, actual = paired("build_worker_detail", "rig", data, state)
    assert actual == expected
    assert actual["editable"] is False
    assert actual["config_origin"] == origin
    assert actual["config_drift"] == drift


def test_not_found_worker_contract_matches(monkeypatch):
    from mining_dashboard.config import config

    monkeypatch.setattr(config, "DASHBOARD_WORKERS", [])
    expected, actual = paired(
        "build_worker_detail", "ghost", {"timestamp": NOW, "workers": []}, State()
    )
    assert actual == expected
    assert actual["found"] is False
    assert actual["ip"] is None


@pytest.mark.asyncio
async def test_http_worker_owns_detail_body(aiohttp_client, monkeypatch):
    from mining_dashboard.config import config
    from mining_dashboard.service.storage_service import StateManager
    from mining_dashboard.web import server

    monkeypatch.setattr(config, "DASHBOARD_CONTROL_ENABLED", True)
    monkeypatch.setattr(
        config,
        "DASHBOARD_WORKERS",
        [{"name": "rig", "host": "rig.example.com", "control_port": 8082}],
    )
    state = StateManager(db_path=":memory:")
    data = {"timestamp": NOW, "workers": [_worker()]}
    try:
        client = await aiohttp_client(server.create_app(state, data))
        response = await client.get("/api/worker?name=rig")
        assert response.status == 200
        body = await response.json()
        assert body["found"] is body["editable"] is True
        assert body["ip"] == "192.0.2.44"
        assert not adapter.FALLBACKS
    finally:
        state.close()
