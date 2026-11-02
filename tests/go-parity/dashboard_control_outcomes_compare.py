import asyncio
import os

import dashboard_control_outcomes_plugin as adapter
import pytest

from mining_dashboard import go_control_outcomes
from mining_dashboard.client import xmrig_client
from mining_dashboard.service import data_audit

# ruff: noqa: S101

pytest_plugins = ["dashboard_control_outcomes_plugin"]
pytestmark = pytest.mark.skipif(
    os.environ.get("PITHEAD_IMPL") != "go", reason="Go dashboard parity only"
)


def _outcome(function, value):
    try:
        return "value", function(value)
    except Exception as error:
        return "error", type(error), str(error)


@pytest.mark.parametrize(
    "payload",
    [
        {},
        {"rigforge": None},
        {"rigforge": {}},
        {"rigforge": {"control": None}},
        {"rigforge": {"control": {}}},
        {"rigforge": {"control": {"change_id": "", "status": "applied"}}},
        {"rigforge": {"control": {"change_id": 7, "status": "applied"}}},
        {"rigforge": {"control": {"change_id": "c1", "status": 7}}},
        {"rigforge": {"control": {"change_id": "c1", "status": "running"}}},
        {"rigforge": {"control": {"change_id": "c1", "status": "applied", "reason": "kept"}}},
    ],
)
def test_current_control_matches_reference(payload):
    with adapter.python_operations():
        expected = _outcome(adapter.ORIGINALS["parse_worker_control_status"], payload)
    assert _outcome(xmrig_client.parse_worker_control_status, payload) == expected


def test_current_control_preserves_field_identity():
    change_id = "".join(["change", "-id"])
    status = "".join(["app", "lied"])
    reason = object()
    payload = {
        "rigforge": {"control": {"change_id": change_id, "status": status, "reason": reason}}
    }
    result = xmrig_client.parse_worker_control_status(payload)
    assert result["change_id"] is change_id
    assert result["status"] is status
    assert result["reason"] is reason


def test_history_matches_reference_and_keeps_duplicates():
    reason = object()
    payload = {
        "rigforge": {
            "control_history": [
                None,
                {"change_id": "c1", "status": "applied", "reason": reason},
                {"change_id": "c1", "status": "applied", "reason": reason},
                {"change_id": "c2", "status": "running", "reason": "ignored"},
            ]
        }
    }
    with adapter.python_operations():
        expected = list(adapter.ORIGINALS["_terminal_control_history"](payload))
    actual = list(data_audit._terminal_control_history(payload))
    assert actual == expected
    assert len(actual) == 2
    assert actual[0][2] is reason
    assert actual[1][2] is reason


def test_history_remains_lazy():
    payload = {
        "rigforge": {"control_history": [{"change_id": "c1", "status": "applied", "reason": None}]}
    }
    before = adapter.CALLS["control-outcomes"]
    outcomes = data_audit._terminal_control_history(payload)
    assert adapter.CALLS["control-outcomes"] == before
    assert next(outcomes) == ("c1", "applied", None)
    assert adapter.CALLS["control-outcomes"] == before + 1


def test_unsupported_history_lookahead_is_bounded():
    rows = [{"rigforge": {"control_history": [None] * 20}} for _ in range(5000)]
    scope = go_control_outcomes._PollScope(rows)
    token = go_control_outcomes._SCOPE.set(scope)
    before = adapter.CALLS["control-outcomes"]
    try:
        assert list(
            data_audit._terminal_control_history(
                {"rigforge": {"control_history": [{"change_id": "c1", "status": "applied"}]}}
            )
        ) == [("c1", "applied", None)]
        assert next(scope.cursors["history"]) is None
    finally:
        go_control_outcomes._SCOPE.reset(token)
    assert adapter.CALLS["control-outcomes"] == before + 1


def test_history_limit_replacement_preserves_slice_protocol(monkeypatch):
    class Limit:
        def __index__(self):
            return 1

    monkeypatch.setattr(data_audit, "_CONTROL_HISTORY_LIMIT", Limit())
    before = adapter.COMPATIBILITY["_history_compat:history-limit"]
    outcomes = list(
        data_audit._terminal_control_history(
            {
                "rigforge": {
                    "control_history": [
                        {"change_id": "c1", "status": "applied"},
                        {"change_id": "c2", "status": "failed"},
                    ]
                }
            }
        )
    )
    assert outcomes == [("c1", "applied", None)]
    assert adapter.COMPATIBILITY["_history_compat:history-limit"] == before + 1


def test_history_lookahead_respects_current_limit(monkeypatch):
    payload = {
        "rigforge": {
            "control_history": [
                {"change_id": "c1", "status": "applied"},
                {"change_id": "c2", "status": "failed"},
            ]
        }
    }
    monkeypatch.setattr(data_audit, "_CONTROL_HISTORY_LIMIT", 1)
    requests = []
    call = go_control_outcomes.go_channel.call

    def observed(helper, request):
        requests.append(request)
        return call(helper, request)

    monkeypatch.setattr(go_control_outcomes.go_channel, "call", observed)
    scope = go_control_outcomes._PollScope([payload])
    token = go_control_outcomes._SCOPE.set(scope)
    try:
        assert list(data_audit._terminal_control_history(payload)) == [("c1", "applied", None)]
    finally:
        go_control_outcomes._SCOPE.reset(token)
    assert len(requests[0]["rows"]) == 1


def test_replaced_selectors_keep_original_callback_order(monkeypatch):
    from mining_dashboard.service.workers import worker_change_audit

    events = []

    async def drift(*_args):
        events.append("drift")

    def current(_payload):
        events.append("current")
        return {"change_id": "current", "status": "applied", "reason": "now"}

    def history(_payload):
        events.append("history")
        yield "history", "failed", "past"

    class State:
        def worker_config_change_known(self, change_id):
            events.append(f"known:{change_id}")
            return True

        def reconcile_worker_config_status(self, change_id, _status, _reason):
            events.append(f"reconcile:{change_id}")

    class Service:
        state_manager = State()

    monkeypatch.setattr(worker_change_audit, "note_revision_drift", drift)
    monkeypatch.setattr(data_audit, "parse_worker_control_status", current)
    monkeypatch.setattr(data_audit, "_terminal_control_history", history)
    before = adapter.CALLS["control-outcomes"]
    asyncio.run(
        go_control_outcomes._reconcile_worker_config(
            Service(), [{"name": "worker"}], [{"payload": True}]
        )
    )
    assert events == [
        "drift",
        "current",
        "history",
        "known:history",
        "reconcile:history",
        "known:current",
        "reconcile:current",
    ]
    assert adapter.CALLS["control-outcomes"] == before


def test_drift_replacement_is_observed_after_await(monkeypatch):
    from mining_dashboard.service.workers import worker_change_audit

    events = []

    def initial_history(_payload):
        events.append("initial-history")
        return iter(())

    def late_current(_payload):
        events.append("late-current")
        return None

    def late_history(_payload):
        events.append("late-history")
        return iter(())

    async def drift(*_args):
        events.append("drift")
        monkeypatch.setattr(data_audit, "parse_worker_control_status", late_current)
        monkeypatch.setattr(data_audit, "_terminal_control_history", late_history)

    class Service:
        state_manager = object()

    monkeypatch.setattr(worker_change_audit, "note_revision_drift", drift)
    monkeypatch.setattr(data_audit, "_terminal_control_history", initial_history)
    before = adapter.CALLS["control-outcomes"]
    asyncio.run(
        go_control_outcomes._reconcile_worker_config(
            Service(), [{"name": "worker"}], [{"payload": True}]
        )
    )
    assert events == ["drift", "late-current", "late-history"]
    assert adapter.CALLS["control-outcomes"] == before


def test_reference_flag_resets_after_cancellation(monkeypatch):
    async def cancelled(*_args):
        assert go_control_outcomes._REFERENCE_ONLY.get() is True
        assert go_control_outcomes._SCOPE.get() is None
        raise asyncio.CancelledError

    monkeypatch.setitem(go_control_outcomes.NATIVE_FUNCTIONS, "_reconcile_worker_config", cancelled)
    monkeypatch.setattr(data_audit, "_terminal_control_history", lambda _payload: iter(()))

    class Service:
        pass

    with pytest.raises(asyncio.CancelledError):
        asyncio.run(go_control_outcomes._reconcile_worker_config(Service(), [], []))
    assert go_control_outcomes._REFERENCE_ONLY.get() is False
    assert go_control_outcomes._SCOPE.get() is None


def test_reference_flag_is_isolated_from_sibling_task(monkeypatch):
    from mining_dashboard.service.workers import worker_change_audit

    async def scenario():
        entered = asyncio.Event()
        release = asyncio.Event()

        async def drift(*_args):
            entered.set()
            await release.wait()

        def history(_payload):
            return iter(())

        class Service:
            state_manager = object()

        monkeypatch.setattr(worker_change_audit, "note_revision_drift", drift)
        monkeypatch.setattr(data_audit, "_terminal_control_history", history)
        task = asyncio.create_task(
            go_control_outcomes._reconcile_worker_config(
                Service(), [{"name": "worker"}], [{"payload": True}]
            )
        )
        await entered.wait()
        before = adapter.CALLS["control-outcomes"]
        result = xmrig_client.parse_worker_control_status(
            {"rigforge": {"control": {"change_id": "c1", "status": "applied"}}}
        )
        assert result["change_id"] == "c1"
        assert adapter.CALLS["control-outcomes"] == before + 1
        release.set()
        await task

    asyncio.run(scenario())
