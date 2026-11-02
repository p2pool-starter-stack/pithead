import builtins
import os

import dashboard_config_meta_plugin as adapter
import pytest

from mining_dashboard import go_config_meta
from mining_dashboard.client import rig_config_meta

# ruff: noqa: S101

pytest_plugins = ["dashboard_config_meta_plugin"]
pytestmark = pytest.mark.skipif(
    os.environ.get("PITHEAD_IMPL") != "go", reason="Go dashboard parity only"
)

GOOD = {
    "revision": "a1b2c3d4e5f60718",
    "changed_at": "2026-08-23T14:30:45Z",
    "source": "control",
    "last_change_id": "0f1e2d3c4b5a6978",
}


def _outcome(function, meta):
    try:
        return "value", function(meta)
    except Exception as error:
        return "error", type(error), str(error)


def test_dict_subclass_preserves_source_first_access_order():
    events = []

    class Meta(dict):
        def get(self, key, default=None):
            events.append(("get", key))
            return super().get(key, default)

        def __getitem__(self, key):
            events.append(("item", key))
            return super().__getitem__(key)

    meta = Meta(GOOD)
    expected = _outcome(go_config_meta.COMPAT_FUNCTIONS["parse_config_meta"], meta)
    expected_events = list(events)
    events.clear()
    actual = _outcome(rig_config_meta.parse_config_meta, meta)
    assert actual == expected
    assert events == expected_events
    assert events[0] == ("get", "source")
    assert adapter.COMPATIBILITY["container"] >= 1


def test_string_subclass_preserves_reference_identity():
    class Token(str):
        pass

    token = Token("subclass_token")
    meta = {**GOOD, "revision": token}
    actual = rig_config_meta.parse_config_meta(meta)
    assert actual["revision"] is token
    assert adapter.COMPATIBILITY["value"] >= 1


def test_surrogate_value_uses_reference_rejection():
    meta = {**GOOD, "revision": "bad\ud800token"}
    assert rig_config_meta.parse_config_meta(meta)["revision"] is None
    assert adapter.COMPATIBILITY["value"] >= 1


def test_custom_key_falls_back_before_lookup_side_effects():
    events = []

    class Key:
        def __hash__(self):
            return hash("source")

        def __eq__(self, other):
            events.append(other)
            return False

    meta = {Key(): "opaque", **GOOD}
    events.clear()
    expected = _outcome(go_config_meta.COMPAT_FUNCTIONS["parse_config_meta"], meta)
    expected_events = list(events)
    events.clear()
    assert _outcome(rig_config_meta.parse_config_meta, meta) == expected
    assert events == expected_events
    assert adapter.COMPATIBILITY["key"] >= 1


def test_replaced_token_provider_runs_once(monkeypatch):
    calls = []
    original = rig_config_meta._token

    def token(value):
        calls.append(value)
        return original(value)

    monkeypatch.setattr(rig_config_meta, "_token", token)
    assert rig_config_meta.parse_config_meta(GOOD) == GOOD
    assert calls == [GOOD["revision"], GOOD["last_change_id"]]
    assert adapter.COMPATIBILITY["token-provider"] >= 1


def test_replaced_regex_provider_runs_in_reference_order(monkeypatch):
    calls = []
    original = rig_config_meta._TOKEN_RE

    class Pattern:
        def match(self, value):
            calls.append(value)
            return original.match(value)

    monkeypatch.setattr(rig_config_meta, "_TOKEN_RE", Pattern())
    assert rig_config_meta.parse_config_meta(GOOD) == GOOD
    assert calls == [GOOD["revision"], GOOD["last_change_id"]]
    assert adapter.COMPATIBILITY["regex-provider"] >= 1


def test_replaced_sources_provider_is_not_compared_early(monkeypatch):
    calls = []

    class Sources:
        def __contains__(self, value):
            calls.append(value)
            return value == "control"

    monkeypatch.setattr(rig_config_meta, "CONFIG_SOURCES", Sources())
    assert rig_config_meta.parse_config_meta(GOOD) == GOOD
    assert calls == [GOOD["source"]]
    assert adapter.COMPATIBILITY["sources"] >= 1


def test_replaced_token_limit_uses_reference_policy(monkeypatch):
    token = "x" * 65
    monkeypatch.setattr(rig_config_meta, "_MAX_TOKEN_LEN", 65)
    result = rig_config_meta.parse_config_meta({"revision": token})
    assert result["revision"] is token
    assert adapter.COMPATIBILITY["token-limit"] >= 1


def test_missing_token_provider_preserves_reference_error(monkeypatch):
    monkeypatch.delattr(rig_config_meta, "_token")
    expected = _outcome(go_config_meta.COMPAT_FUNCTIONS["parse_config_meta"], GOOD)
    actual = _outcome(rig_config_meta.parse_config_meta, GOOD)
    assert actual == expected
    assert actual[:2] == ("error", NameError)
    assert adapter.COMPATIBILITY["token-provider"] >= 1


def test_missing_token_limit_preserves_reference_error(monkeypatch):
    monkeypatch.delattr(rig_config_meta, "_MAX_TOKEN_LEN")
    expected = _outcome(go_config_meta.COMPAT_FUNCTIONS["parse_config_meta"], GOOD)
    actual = _outcome(rig_config_meta.parse_config_meta, GOOD)
    assert actual == expected
    assert actual[:2] == ("error", NameError)
    assert adapter.COMPATIBILITY["token-limit"] >= 1


def test_replaced_builtin_provider_runs_reference_policy(monkeypatch):
    calls = []

    def length(value):
        calls.append(value)
        return builtins.len(value)

    monkeypatch.setattr(rig_config_meta, "len", length, raising=False)
    assert rig_config_meta.parse_config_meta(GOOD) == GOOD
    assert calls == [GOOD["revision"], GOOD["last_change_id"]]
    assert adapter.COMPATIBILITY["builtin-provider"] >= 1


def test_opaque_rejected_value_stays_off_wire(monkeypatch):
    captured = []

    def call(helper, request):
        captured.append((helper, request))
        return {name: False for name in ("revision", "changed_at", "source", "last_change_id")}

    go_config_meta._native_plan.cache_clear()
    monkeypatch.setattr(go_config_meta.go_channel, "call", call)
    opaque = {"nested": [object()]}
    assert rig_config_meta.parse_config_meta({"revision": opaque}) is None
    fields = captured[0][1]["args"][0]
    assert fields["revision"] == {"kind": "other"}
    assert "nested" not in repr(fields)


def test_oversized_surrogate_value_is_not_carried_on_wire(monkeypatch):
    captured = []

    def call(_helper, request):
        captured.append(request)
        return {name: False for name in ("revision", "changed_at", "source", "last_change_id")}

    go_config_meta._native_plan.cache_clear()
    monkeypatch.setattr(go_config_meta.go_channel, "call", call)
    assert rig_config_meta.parse_config_meta({"revision": "\ud800" + "x" * 64}) is None
    assert captured[0]["args"][0]["revision"] == {"kind": "string", "length": 65}


@pytest.mark.parametrize(
    "reply",
    [
        {},
        {"revision": False, "changed_at": False, "source": False},
        {"revision": 0, "changed_at": False, "source": False, "last_change_id": False},
        {
            "revision": False,
            "changed_at": False,
            "source": False,
            "last_change_id": False,
            "extra": False,
        },
    ],
)
def test_malformed_native_reply_is_fatal(monkeypatch, reply):
    go_config_meta._native_plan.cache_clear()
    monkeypatch.setattr(go_config_meta.go_channel, "call", lambda *_args, **_kwargs: reply)
    with pytest.raises(RuntimeError, match="invalid config metadata policy"):
        rig_config_meta.parse_config_meta(GOOD)


def test_native_error_is_fatal(monkeypatch):
    go_config_meta._native_plan.cache_clear()

    def fail(*_args, **_kwargs):
        raise RuntimeError("native unavailable")

    monkeypatch.setattr(go_config_meta.go_channel, "call", fail)
    with pytest.raises(RuntimeError, match="native unavailable"):
        rig_config_meta.parse_config_meta(GOOD)


def test_cache_is_bounded_and_evicts(monkeypatch):
    calls = []

    def call(_helper, request):
        calls.append(request)
        return {name: False for name in ("revision", "changed_at", "source", "last_change_id")}

    monkeypatch.setattr(go_config_meta.go_channel, "call", call)
    go_config_meta._native_plan.cache_clear()
    for index in range(257):
        rig_config_meta.parse_config_meta({"revision": f"token_{index}"})
    assert go_config_meta._native_plan.cache_info().currsize == 256
    rig_config_meta.parse_config_meta({"revision": "token_0"})
    assert len(calls) == 258
