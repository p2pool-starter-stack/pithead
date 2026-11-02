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


def _payload(change_id="c1", status="applied", reason=None):
    return {"rigforge": {"control": {"change_id": change_id, "status": status, "reason": reason}}}


def test_native_request_contains_only_shape_metadata(monkeypatch):
    reason = object()
    payload = _payload("secret-id", "applied", reason)
    requests = []
    call = go_control_outcomes.go_channel.call

    def observed(helper, request):
        if request["operation"] == "control-outcomes":
            requests.append(request)
        return call(helper, request)

    monkeypatch.setattr(go_control_outcomes.go_channel, "call", observed)
    result = xmrig_client.parse_worker_control_status(payload)
    assert result["change_id"] == "secret-id"
    assert result["reason"] is reason
    assert requests == [
        {
            "operation": "control-outcomes",
            "rows": [
                {
                    "id_string": True,
                    "id_nonempty": True,
                    "status_kind": "string",
                    "status": "applied",
                }
            ],
            "terminal": list(xmrig_client._CONTROL_TERMINAL),
        }
    ]
    assert "secret-id" not in repr(requests)


def test_current_reason_is_captured_before_native_exchange(monkeypatch):
    old_reason, new_reason = object(), object()
    payload = _payload(reason=old_reason)
    call = go_control_outcomes.go_channel.call

    def interleaved(helper, request):
        payload["rigforge"]["control"]["reason"] = new_reason
        return call(helper, request)

    monkeypatch.setattr(go_control_outcomes.go_channel, "call", interleaved)
    assert xmrig_client.parse_worker_control_status(payload)["reason"] is old_reason


def test_history_reason_is_captured_before_native_exchange(monkeypatch):
    old_reason, new_reason = object(), object()
    entry = {"change_id": "c1", "status": "applied", "reason": old_reason}
    payload = {"rigforge": {"control_history": [entry]}}
    call = go_control_outcomes.go_channel.call

    def interleaved(helper, request):
        entry["reason"] = new_reason
        return call(helper, request)

    monkeypatch.setattr(go_control_outcomes.go_channel, "call", interleaved)
    assert next(data_audit._terminal_control_history(payload))[2] is old_reason


def test_mutated_future_current_row_gets_a_fresh_selection():
    rows = [_payload("c1", "applied"), _payload("c2", "rejected")]
    scope = go_control_outcomes._PollScope(rows)
    token = go_control_outcomes._SCOPE.set(scope)
    before = adapter.CALLS["control-outcomes"]
    try:
        assert xmrig_client.parse_worker_control_status(rows[0])["status"] == "applied"
        rows[1]["rigforge"]["control"]["status"] = "running"
        assert xmrig_client.parse_worker_control_status(rows[1]) is None
    finally:
        go_control_outcomes._SCOPE.reset(token)
    assert adapter.CALLS["control-outcomes"] == before + 2


def test_mutated_future_history_row_gets_a_fresh_selection():
    entries = [
        {"change_id": "c1", "status": "applied", "reason": None},
        {"change_id": "c2", "status": "rejected", "reason": None},
    ]
    rows = [{"rigforge": {"control_history": entries}}]
    scope = go_control_outcomes._PollScope(rows)
    token = go_control_outcomes._SCOPE.set(scope)
    before = adapter.CALLS["control-outcomes"]
    try:
        outcomes = data_audit._terminal_control_history(rows[0])
        assert next(outcomes) == ("c1", "applied", None)
        entries[1]["status"] = "running"
        with pytest.raises(StopIteration):
            next(outcomes)
    finally:
        go_control_outcomes._SCOPE.reset(token)
    assert adapter.CALLS["control-outcomes"] == before + 2


def test_vocabulary_change_uses_a_distinct_cache_key(monkeypatch):
    rows = [_payload("c1", "applied")]
    scope = go_control_outcomes._PollScope(rows)
    token = go_control_outcomes._SCOPE.set(scope)
    before = adapter.CALLS["control-outcomes"]
    try:
        assert xmrig_client.parse_worker_control_status(rows[0])["status"] == "applied"
        monkeypatch.setattr(xmrig_client, "_CONTROL_TERMINAL", ["rejected"])
        assert xmrig_client.parse_worker_control_status(rows[0]) is None
    finally:
        go_control_outcomes._SCOPE.reset(token)
    assert adapter.CALLS["control-outcomes"] == before + 2


def test_history_refreshes_vocabulary_after_each_yield(monkeypatch):
    entries = [
        {"change_id": "c1", "status": "applied", "reason": None},
        {"change_id": "c2", "status": "custom", "reason": None},
    ]
    outcomes = data_audit._terminal_control_history({"rigforge": {"control_history": entries}})
    assert next(outcomes) == ("c1", "applied", None)
    monkeypatch.setattr(data_audit, "_CONTROL_TERMINAL", ("custom",))
    assert next(outcomes) == ("c2", "custom", None)


def test_history_refreshes_entry_provider_after_each_yield(monkeypatch):
    entries = [
        {"change_id": "c1", "status": "applied", "reason": None},
        {"change_id": "c2", "status": "running", "reason": "custom"},
    ]
    outcomes = data_audit._terminal_control_history({"rigforge": {"control_history": entries}})
    assert next(outcomes) == ("c1", "applied", None)

    def provider(entry):
        return entry["change_id"], entry["status"], entry["reason"]

    monkeypatch.setattr(data_audit, "_terminal_control_entry", provider)
    assert next(outcomes) == ("c2", "running", "custom")


def test_custom_status_comparison_uses_reference_policy():
    comparisons = []

    class Status:
        def __eq__(self, other):
            comparisons.append(other)
            return other == "applied"

    status = Status()
    current_before = adapter.COMPATIBILITY["_current_compat:status-comparison"]
    assert xmrig_client.parse_worker_control_status(_payload(status=status))["status"] is status
    history_before = adapter.COMPATIBILITY["_entry_compat:status-comparison"]
    outcomes = data_audit._terminal_control_history(
        {"rigforge": {"control_history": [{"change_id": "c1", "status": status, "reason": None}]}}
    )
    assert next(outcomes)[1] is status
    assert comparisons == list(xmrig_client._CONTROL_TERMINAL)[:1] * 2
    assert adapter.COMPATIBILITY["_current_compat:status-comparison"] == current_before + 1
    assert adapter.COMPATIBILITY["_entry_compat:status-comparison"] == history_before + 1


def test_drift_await_mutation_forces_fresh_later_current_selection(monkeypatch):
    from mining_dashboard.service.workers import worker_change_audit

    rows = [_payload("c1", "running"), _payload("c2", "applied")]
    calls = []

    async def drift(_service, _worker, _extra, _cap, _window):
        calls.append("drift")
        if len(calls) == 2:
            rows[1]["rigforge"]["control"]["status"] = "started"
        await asyncio.sleep(0)

    monkeypatch.setattr(worker_change_audit, "note_revision_drift", drift)
    before = adapter.CALLS["control-outcomes"]

    class Service:
        pass

    asyncio.run(
        go_control_outcomes._reconcile_worker_config(
            Service(), [{"name": "one"}, {"name": "two"}], rows
        )
    )
    assert calls == ["drift", "drift"]
    assert adapter.CALLS["control-outcomes"] == before + 2


def test_database_await_mutation_forces_fresh_later_history_selection(monkeypatch):
    from mining_dashboard.service.workers import worker_change_audit

    entries = [
        {"change_id": "c1", "status": "applied", "reason": "first"},
        {"change_id": "c2", "status": "rejected", "reason": "second"},
    ]
    rows = [{"rigforge": {"control_history": entries}}]

    async def drift(*_args):
        return None

    monkeypatch.setattr(worker_change_audit, "note_revision_drift", drift)

    class State:
        def __init__(self):
            self.reconciled = []

        def worker_config_change_known(self, change_id):
            if change_id == "c1":
                entries[1]["status"] = "failed"
            return True

        def reconcile_worker_config_status(self, change_id, status, reason):
            self.reconciled.append((change_id, status, reason))

    class Service:
        state_manager = State()

    before = adapter.CALLS["control-outcomes"]
    service = Service()
    asyncio.run(go_control_outcomes._reconcile_worker_config(service, [{"name": "one"}], rows))
    assert service.state_manager.reconciled == [
        ("c1", "applied", "first"),
        ("c2", "failed", "second"),
    ]
    assert adapter.CALLS["control-outcomes"] == before + 3


def test_large_rotating_fleet_batches_unique_shapes():
    rows = [_payload(f"c{index}", f"status-{index}") for index in range(600)]
    scope = go_control_outcomes._PollScope(rows)
    token = go_control_outcomes._SCOPE.set(scope)
    before = adapter.CALLS["control-outcomes"]
    try:
        assert all(xmrig_client.parse_worker_control_status(row) is None for row in rows)
    finally:
        go_control_outcomes._SCOPE.reset(token)
    assert adapter.CALLS["control-outcomes"] == before + 3
    assert len(scope.caches["current"]) <= 512


def test_mixed_large_fleet_keeps_current_and_history_plans_separate():
    rows = [
        {
            **_payload(f"current-{index}", f"current-status-{index}"),
            "rigforge": {
                **_payload(f"current-{index}", f"current-status-{index}")["rigforge"],
                "control_history": [
                    {
                        "change_id": f"history-{index}",
                        "status": f"history-status-{index}",
                    }
                ],
            },
        }
        for index in range(600)
    ]
    scope = go_control_outcomes._PollScope(rows)
    token = go_control_outcomes._SCOPE.set(scope)
    before = adapter.CALLS["control-outcomes"]
    try:
        assert xmrig_client.parse_worker_control_status(rows[0]) is None
        for row in rows[:300]:
            assert list(data_audit._terminal_control_history(row)) == []
        assert xmrig_client.parse_worker_control_status(rows[1]) is None
    finally:
        go_control_outcomes._SCOPE.reset(token)
    assert adapter.CALLS["control-outcomes"] == before + 3


def test_extra_results_beyond_workers_are_not_examined():
    rows = [_payload(f"c{index}", "applied") for index in range(300)]
    before = adapter.CALLS["control-outcomes"]

    class Service:
        pass

    asyncio.run(go_control_outcomes._reconcile_worker_config(Service(), [], rows))
    assert adapter.CALLS["control-outcomes"] == before


def test_custom_worker_results_take_whole_poll_compatibility():
    iterations = []

    class Results:
        def __iter__(self):
            iterations.append("iter")
            return iter(())

    before = adapter.COMPATIBILITY["_reconcile_compat:worker-results-shape"]

    class Service:
        pass

    asyncio.run(go_control_outcomes._reconcile_worker_config(Service(), [], Results()))
    assert iterations == ["iter"]
    assert adapter.COMPATIBILITY["_reconcile_compat:worker-results-shape"] == before + 1


def test_cancelled_reconciliation_resets_poll_scope(monkeypatch):
    async def cancelled(*_args):
        assert go_control_outcomes._SCOPE.get() is not None
        raise asyncio.CancelledError

    monkeypatch.setitem(go_control_outcomes.NATIVE_FUNCTIONS, "_reconcile_worker_config", cancelled)

    class Service:
        pass

    with pytest.raises(asyncio.CancelledError):
        asyncio.run(go_control_outcomes._reconcile_worker_config(Service(), [], []))
    assert go_control_outcomes._SCOPE.get() is None


def test_exact_replaced_vocabulary_is_sent_to_native(monkeypatch):
    monkeypatch.setattr(xmrig_client, "_CONTROL_TERMINAL", ["custom", "custom"])
    before = adapter.CALLS["control-outcomes"]
    result = xmrig_client.parse_worker_control_status(_payload(status="custom"))
    assert result["status"] == "custom"
    assert adapter.CALLS["control-outcomes"] == before + 1


def test_custom_vocabulary_comparison_stays_reference(monkeypatch):
    calls = []

    class Vocabulary:
        def __contains__(self, status):
            calls.append(status)
            return status == "custom"

    monkeypatch.setattr(xmrig_client, "_CONTROL_TERMINAL", Vocabulary())
    before = adapter.COMPATIBILITY["_current_compat:terminal-vocabulary"]
    result = xmrig_client.parse_worker_control_status(_payload(status="custom"))
    assert result["status"] == "custom"
    assert calls == ["custom"]
    assert adapter.COMPATIBILITY["_current_compat:terminal-vocabulary"] == before + 1


def test_oversized_status_uses_explicit_compatibility():
    status = "x" * 257
    before = adapter.COMPATIBILITY["_current_compat:status-size"]
    assert xmrig_client.parse_worker_control_status(_payload(status=status)) is None
    assert adapter.COMPATIBILITY["_current_compat:status-size"] == before + 1


def test_custom_history_entry_uses_shared_entry_helper():
    reason = object()

    class Entry(dict):
        pass

    entry = Entry(change_id="c1", status="applied", reason=reason)
    payload = {"rigforge": {"control_history": [entry]}}
    before = adapter.COMPATIBILITY["_entry_compat:entry-shape"]
    assert list(data_audit._terminal_control_history(payload)) == [("c1", "applied", reason)]
    assert adapter.COMPATIBILITY["_entry_compat:entry-shape"] == before + 1


def test_malformed_and_inconsistent_native_results_are_fatal(monkeypatch):
    monkeypatch.setattr(go_control_outcomes.go_channel, "call", lambda *_args, **_kwargs: [False])
    with pytest.raises(RuntimeError, match="inconsistent control outcome"):
        xmrig_client.parse_worker_control_status(_payload())

    monkeypatch.setattr(go_control_outcomes.go_channel, "call", lambda *_args, **_kwargs: {})
    with pytest.raises(RuntimeError, match="invalid control outcomes"):
        xmrig_client.parse_worker_control_status(_payload())
