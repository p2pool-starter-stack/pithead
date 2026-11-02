from contextvars import ContextVar

import pytest

from mining_dashboard import go_control_outcomes as bridge
from mining_dashboard.client import xmrig_client
from mining_dashboard.service import data_audit


@pytest.fixture
def policy(monkeypatch):
    requests, replies, compatibility = [], [], []

    def call(helper, payload):
        requests.append((helper, payload))
        return replies.pop(0)

    def current(payload):
        compatibility.append(payload)
        return "reference"

    def history(payload):
        compatibility.append(payload)
        yield ("reference", "done", None)

    monkeypatch.setattr(bridge.go_channel, "call", call)
    monkeypatch.setattr(
        bridge,
        "COMPAT_FUNCTIONS",
        {"parse_worker_control_status": current, "_terminal_control_history": history},
    )
    monkeypatch.setattr(bridge, "NATIVE_FUNCTIONS", {})
    monkeypatch.setattr(bridge, "PROVIDERS", {"entry": data_audit._terminal_control_entry})
    monkeypatch.setattr(bridge, "_SCOPE", ContextVar("contract_scope", default=None))
    monkeypatch.setattr(bridge, "_REFERENCE_ONLY", ContextVar("contract_reference", default=False))
    monkeypatch.setattr(xmrig_client, "_CONTROL_TERMINAL", ("done", "failed"))
    monkeypatch.setattr(data_audit, "_CONTROL_TERMINAL", ("done", "failed"))
    monkeypatch.setattr(data_audit, "_CONTROL_HISTORY_LIMIT", 10)
    return requests, replies, compatibility


def payload(identifier="change", status="done", reason=None):
    return {"rigforge": {"control": {"change_id": identifier, "status": status, "reason": reason}}}


@pytest.mark.parametrize(
    ("value", "selected", "row", "terminal"),
    [
        ({}, False, {"id_string": False, "id_nonempty": False, "status_kind": "other"}, []),
        (payload(""), False, {"id_string": True, "id_nonempty": False, "status_kind": "other"}, []),
        (
            payload(status="pending"),
            False,
            {"id_string": True, "id_nonempty": True, "status_kind": "string", "status": "pending"},
            ["done", "failed"],
        ),
        (
            payload(),
            True,
            {"id_string": True, "id_nonempty": True, "status_kind": "string", "status": "done"},
            ["done", "failed"],
        ),
    ],
)
def test_current_status_consumes_checked_boolean_plan(policy, value, selected, row, terminal):
    requests, replies, compatibility = policy
    replies.append([selected])
    result = bridge.parse_worker_control_status(value)
    assert result == (
        {"change_id": "change", "status": "done", "reason": None} if selected else None
    )
    assert requests == [
        ("network", {"operation": "control-outcomes", "rows": [row], "terminal": terminal})
    ]
    assert not compatibility


def test_current_status_retains_opaque_identifier_and_reason(policy):
    requests, replies, _compatibility = policy
    identifier = "\ud800"
    reason = object()
    replies.append([True])
    result = bridge.parse_worker_control_status(payload(identifier, reason=reason))
    assert result["change_id"] is identifier and result["reason"] is reason
    assert "change_id" not in requests[0][1]["rows"][0]


class Text(str):
    pass


class Mapping(dict):
    pass


@pytest.mark.parametrize(
    "value",
    [
        None,
        Mapping(),
        {"rigforge": Mapping()},
        {"rigforge": {"control": Mapping()}},
        payload(Text("change")),
        payload(status=Text("done")),
        payload(status=[]),
        payload(status="x" * 257),
    ],
)
def test_current_compatibility_preserves_original_payload(policy, value):
    requests, _replies, compatibility = policy
    assert bridge.parse_worker_control_status(value) == "reference"
    assert compatibility == [value] and not requests


def test_terminal_vocabulary_and_reference_scope_are_explicit(policy, monkeypatch):
    requests, _replies, compatibility = policy
    monkeypatch.setattr(xmrig_client, "_CONTROL_TERMINAL", {"done"})
    value = payload()
    assert bridge.parse_worker_control_status(value) == "reference"
    token = bridge._REFERENCE_ONLY.set(True)
    try:
        assert bridge.parse_worker_control_status(value) == "reference"
    finally:
        bridge._REFERENCE_ONLY.reset(token)
    assert compatibility == [value, value] and not requests


@pytest.mark.parametrize("reply", [None, [], [1], [True, False]])
def test_native_reply_shape_is_strict(policy, reply):
    _requests, replies, _compatibility = policy
    replies.append(reply)
    with pytest.raises(RuntimeError, match="invalid control outcomes"):
        bridge.parse_worker_control_status(payload())


def test_native_result_must_match_the_supplied_terminal_metadata(policy, monkeypatch):
    requests, replies, _compatibility = policy
    replies.append([False])
    with pytest.raises(RuntimeError, match="inconsistent control outcome"):
        bridge.parse_worker_control_status(payload())
    monkeypatch.setattr(bridge, "_MAX_REQUEST_BYTES", 1)
    with pytest.raises(RuntimeError, match="exceeds size limit"):
        bridge.parse_worker_control_status(payload())
    assert len(requests) == 1


def test_metadata_and_lookahead_reject_unsupported_values(policy):
    assert bridge._vocabulary(["done"]) == ("done",)
    assert bridge._vocabulary(["x"] * 65) is None
    assert bridge._vocabulary([Text("done")]) is None
    assert not bridge._utf8_within("\ud800", 10)
    assert not bridge._utf8_within("éé", 3)
    assert not bridge._dict_keys({1: "value"})
    assert (
        bridge._lookahead_current({"rigforge": {"control": {"change_id": "id", "status": []}}})
        is None
    )
    assert bridge._lookahead_current({"rigforge": None}) == (False, False, "other", None)
    assert bridge._lookahead_current(None) is None
    assert bridge._lookahead_current({"rigforge": []}) is None
    assert bridge._lookahead_current({"rigforge": {"control": []}}) is None


@pytest.mark.parametrize(
    "value,limit",
    [
        (None, 1),
        ({}, 1),
        ({"rigforge": {}}, 1),
        ({"rigforge": {"control_history": []}}, 0),
        ({}, None),
    ],
)
def test_history_lookahead_marks_unsupported_or_empty_sources(policy, value, limit):
    assert list(bridge._lookahead_history(value, limit)) == [None]


def test_history_lookahead_preserves_slice_and_skips_bad_rows(policy):
    value = {
        "rigforge": {
            "control_history": [
                None,
                {"change_id": "id", "status": []},
                {"change_id": "id", "status": "done"},
            ]
        }
    }
    assert list(bridge._lookahead_history(value, -1)) == [None, None]
    assert list(bridge._lookahead_history(value, 3))[-1] == (True, True, "string", "done")


def test_poll_scope_batches_and_caches_unique_metadata(policy, monkeypatch):
    requests, replies, _compatibility = policy
    replies.append([True, False])
    scope = bridge._PollScope([payload(), payload(status="pending"), payload()])
    terminal = ("done", "failed")
    assert scope.selected("current", (True, True, "string", "done"), terminal) is True
    assert scope.selected("current", (True, True, "string", "pending"), terminal) is False
    assert len(requests) == 1 and len(requests[0][1]["rows"]) == 2
    monkeypatch.setattr(bridge, "_MAX_CACHE", 1)
    monkeypatch.setattr(bridge, "_MAX_ROWS", 1)
    scope = bridge._PollScope([])
    replies.extend([[True], [False], [True]])
    assert scope.selected("current", (True, True, "string", "done"), terminal)
    assert not scope.selected("current", (True, True, "string", "pending"), terminal)
    assert scope.selected("current", (True, True, "string", "done"), terminal)
    assert len(scope.caches["current"]) == 1


def test_history_selection_and_entry_provider_preserve_order(policy, monkeypatch):
    _requests, replies, _compatibility = policy
    reason = object()
    rows = [
        None,
        {"change_id": "a", "status": "done", "reason": reason},
        {"change_id": "b", "status": "pending"},
        {"change_id": "", "status": "done"},
    ]
    replies.extend([[True], [False]])
    result = list(bridge._terminal_control_history({"rigforge": {"control_history": rows}}))
    assert result == [("a", "done", reason)]
    seen = []
    monkeypatch.setattr(
        data_audit,
        "_terminal_control_entry",
        lambda entry: seen.append(entry) or ("provider", "done", None),
    )
    assert (
        list(bridge._terminal_control_history({"rigforge": {"control_history": rows}}))
        == [("provider", "done", None)] * 4
    )
    assert seen == rows


@pytest.mark.parametrize(
    "value", [None, {"rigforge": Mapping()}, {"rigforge": {"control_history": Text("bad")}}]
)
def test_history_compatibility_preserves_container(policy, value):
    _requests, _replies, compatibility = policy
    if isinstance(value, dict) and type(value.get("rigforge", {}).get("control_history")) is Text:
        assert list(bridge._terminal_control_history(value)) == []
    else:
        assert list(bridge._terminal_control_history(value)) == [("reference", "done", None)]
        assert compatibility == [value]


@pytest.mark.asyncio
async def test_reconcile_scope_resets_after_success_failure_and_compatibility(policy, monkeypatch):
    _requests, _replies, _compatibility = policy
    seen = []

    async def method(owner, workers, results):
        seen.append((owner, workers, results, bridge._SCOPE.get(), bridge._REFERENCE_ONLY.get()))
        if owner == "fail":
            raise ValueError("failed")
        return "reconciled"

    monkeypatch.setitem(bridge.NATIVE_FUNCTIONS, "_reconcile_worker_config", method)
    monkeypatch.setattr(
        data_audit, "parse_worker_control_status", bridge.parse_worker_control_status
    )
    monkeypatch.setattr(data_audit, "_terminal_control_history", bridge._terminal_control_history)
    assert await bridge._reconcile_worker_config("owner", [1], [{}]) == "reconciled"
    assert isinstance(seen[-1][3], bridge._PollScope) and seen[-1][4] is False
    assert bridge._SCOPE.get() is None
    with pytest.raises(ValueError):
        await bridge._reconcile_worker_config("fail", [1], [{}])
    assert bridge._SCOPE.get() is None
    assert await bridge._reconcile_worker_config("owner", iter([1]), [{}]) == "reconciled"
    assert seen[-1][4] is True and bridge._REFERENCE_ONLY.get() is False
    monkeypatch.setattr(data_audit, "parse_worker_control_status", object())
    assert await bridge._reconcile_worker_config("owner", [1], [{}]) == "reconciled"
    assert seen[-1][4] is True
