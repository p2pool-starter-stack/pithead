import asyncio
import json
import os
import threading
from datetime import UTC, datetime
from types import SimpleNamespace

import pytest
from dashboard_worker_detail_compare import State

from mining_dashboard import go_worker_detail, go_worker_http
from mining_dashboard.go_control_http import _NativeFailure

# ruff: noqa: S101

pytestmark = pytest.mark.skipif(
    os.environ.get("PITHEAD_IMPL") != "go", reason="Go dashboard parity only"
)
NOW = 1_760_000_000.0


@pytest.mark.asyncio
async def test_worker_builder_runs_off_loop_with_frozen_data_and_clock(monkeypatch):
    from mining_dashboard.web import server

    clock = [NOW]
    monkeypatch.setattr(go_worker_detail.time, "time", lambda: clock[0])
    monkeypatch.setattr(server, "build_worker_detail", go_worker_detail.build_worker_detail)
    data = {
        "timestamp": NOW,
        "workers": [
            {
                "name": "rig1",
                "status": "online",
                "h60": 2000,
                "rigforge": {
                    "generated_at": datetime.fromtimestamp(NOW, UTC)
                    .isoformat()
                    .replace("+00:00", "Z"),
                    "version": "1.2.3",
                },
            }
        ],
    }
    started = threading.Event()
    released = threading.Event()
    loop_thread = threading.get_ident()

    class SlowState(State):
        def get_worker_config_history(self, worker, limit=50):
            assert threading.get_ident() != loop_thread
            started.set()
            assert released.wait(5)
            return super().get_worker_config_history(worker, limit)

    request = SimpleNamespace(
        query={"name": "rig1"}, app={"latest_data": data, "state_manager": SlowState()}
    )
    task = asyncio.create_task(go_worker_http.handle_worker_detail(request))
    try:
        assert await asyncio.to_thread(started.wait, 5)
        await asyncio.sleep(0)
        data["timestamp"] = NOW + 1000
        data["workers"].clear()
        clock[0] = NOW + 1000
        assert not task.done()
    finally:
        released.set()
    response = await asyncio.wait_for(task, 10)
    body = json.loads(response.body)
    assert response.status == 200
    assert body["snapshot_at"] == NOW
    assert body["found"] is True
    assert body["rigforge"]["stale"] is False


@pytest.mark.parametrize("value", [None, [], {}, {"name": "rig1"}])
def test_malformed_native_detail_result_is_fatal(monkeypatch, value):
    monkeypatch.setattr(go_worker_detail, "_run", lambda *_args, **_kwargs: value)
    with pytest.raises(_NativeFailure, match="invalid native worker detail result"):
        go_worker_detail.build_prepared({"now": NOW})


def test_helper_transport_failure_remains_native_failure(monkeypatch):
    def unavailable(*_args, **_kwargs):
        raise RuntimeError("unavailable")

    monkeypatch.setattr(go_worker_detail.go_channel, "call", unavailable)
    with pytest.raises(_NativeFailure, match="native worker detail unavailable"):
        go_worker_detail.config_drift({}, {})


def test_capture_copies_only_selected_worker():
    class Unrelated:
        def __deepcopy__(self, memo):
            raise AssertionError("unrelated fleet data copied")

    data = {
        "timestamp": NOW,
        "workers": [
            {"name": "other", "rigforge": Unrelated()},
            {"name": "rig1", "h60": 2000},
        ],
        "shares": [Unrelated()],
        "system": Unrelated(),
    }
    captured, _now = go_worker_detail.capture("rig1", data)
    assert set(captured) == {"timestamp", "rigforge_release", "workers"}
    assert captured["workers"] == [{"name": "rig1", "h60": 2000}]
    data["workers"][1]["h60"] = 9999
    assert captured["workers"][0]["h60"] == 2000


@pytest.mark.parametrize(
    ("key", "value"),
    [
        ("found", "yes"),
        ("history", {}),
        ("rig_config", []),
        ("hashrate", 1),
        ("hashrate_history", []),
        ("writable_keys", [None]),
    ],
)
def test_full_key_result_with_invalid_types_is_fatal(monkeypatch, key, value):
    result = go_worker_detail.build_worker_detail("rig1", {"workers": []}, State())
    result[key] = value
    monkeypatch.setattr(go_worker_detail, "_run", lambda *_args, **_kwargs: result)
    with pytest.raises(_NativeFailure, match="invalid native worker detail types"):
        go_worker_detail.build_prepared({"now": NOW})


def test_integer_overflow_is_not_reported_as_drift_agreement():
    config = {"DONATION": 10**400}
    with pytest.raises(_NativeFailure, match="native worker detail unavailable"):
        go_worker_detail.config_drift(config, config)
    assert go_worker_detail.config_drift(config, {}, unsettled=True) is None


@pytest.mark.parametrize("history", [{"status": "accepted"}, ["invalid"]])
def test_malformed_unsettled_history_is_fatal(history):
    with pytest.raises(_NativeFailure):
        go_worker_detail._has_unsettled_apply(history)


@pytest.mark.parametrize("history", [{}, [], None])
def test_empty_unsettled_history_remains_false(history):
    assert go_worker_detail._has_unsettled_apply(history) is False


def test_nan_drift_never_claims_agreement():
    config = {"DONATION": float("nan")}
    with pytest.raises(_NativeFailure):
        go_worker_detail.config_drift(config, config)


@pytest.mark.parametrize("history", [False, True])
def test_hashrate_integer_overflow_is_not_rendered_as_zero(history):
    data = {"workers": [{"name": "rig1", "h60": 1 if history else 10**400}]}
    state = State(
        by_config=[{"ts": 0, "avg_h15": 10**400, "min_h15": 0, "max_h15": 0}] if history else []
    )
    with pytest.raises(_NativeFailure, match="native worker detail unavailable"):
        go_worker_detail.build_worker_detail("rig1", data, state)
