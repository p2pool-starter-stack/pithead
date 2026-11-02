from collections import OrderedDict
from types import SimpleNamespace

import pytest

from mining_dashboard import go_audit_cap, go_config_meta
from mining_dashboard.client import rig_config_meta, xmrig_client
from mining_dashboard.service import data_audit
from mining_dashboard.service.workers import worker_change_audit


@pytest.fixture
def cap(monkeypatch):
    monkeypatch.setattr(go_audit_cap, "_CACHE", OrderedDict())
    monkeypatch.setattr(go_audit_cap, "REFERENCE_FUNCTIONS", {})
    monkeypatch.setattr(go_audit_cap, "COMPAT_FUNCTIONS", {})
    monkeypatch.setattr(go_audit_cap, "NATIVE_FUNCTIONS", {})
    return go_audit_cap


def test_audit_cap_plan_is_checked_cached_and_consumed(cap, monkeypatch):
    calls = []
    plan = {
        "limit": 1,
        "names_full": [False, True, True],
        "spend": [[True, False], [False, True], [False, False]],
    }
    monkeypatch.setattr(cap.go_channel, "call", lambda *args: calls.append(args) or plan)
    monkeypatch.setattr(data_audit, "_RIG_EDIT_CAP_PER_HOUR", 1)
    assert cap._names_full(0, 1) is False
    assert cap._names_full(100, 1) is True
    assert cap._count_policy(1) == (False, True)
    assert cap._count_policy(100) == (False, False)
    assert calls == [("network", {"operation": "audit-cap-policy", "limit": 1})]
    assert cap._CACHE[1] == ((False, True, True), ((True, False), (False, True), (False, False)))


@pytest.mark.parametrize(
    "result",
    [
        None,
        {},
        {"limit": True, "names_full": [], "spend": []},
        {"limit": 1, "names_full": [0, 1, 1], "spend": [[True, False]] * 3},
        {"limit": 1, "names_full": [False, True, True], "spend": [[True]] * 3},
    ],
)
def test_audit_cap_rejects_malformed_native_tables(cap, monkeypatch, result):
    monkeypatch.setattr(cap.go_channel, "call", lambda *_args: result)
    with pytest.raises(RuntimeError, match="invalid audit cap policy"):
        cap._plan(1)
    assert not cap._CACHE


def test_audit_cap_cache_evicts_without_reusing_a_different_limit(cap, monkeypatch):
    calls = []

    def table(_helper, payload):
        limit = payload["limit"]
        calls.append(limit)
        return {
            "limit": limit,
            "names_full": [False] * (limit + 2),
            "spend": [[True, False]] * (limit + 2),
        }

    monkeypatch.setattr(cap, "_MAX_CACHE", 2)
    monkeypatch.setattr(cap.go_channel, "call", table)
    for limit in (1, 2, 1, 3, 2):
        cap._plan(limit)
    assert calls == [1, 2, 3, 2] and list(cap._CACHE) == [3, 2]


def test_audit_cap_compatibility_and_opaque_callbacks(cap, monkeypatch):
    calls = []
    monkeypatch.setitem(
        cap.COMPAT_FUNCTIONS, "_names_full", lambda *args: calls.append(("names", args))
    )
    monkeypatch.setitem(
        cap.COMPAT_FUNCTIONS, "_count_policy", lambda *args: calls.append(("count", args))
    )
    cap._names_full(-1, 1)
    cap._names_full(0, 4097)
    monkeypatch.delattr(data_audit, "_RIG_EDIT_CAP_PER_HOUR")
    cap._count_policy(1)
    monkeypatch.setattr(data_audit, "_RIG_EDIT_CAP_PER_HOUR", 1, raising=False)
    cap._count_policy(True)
    assert calls == [("names", (-1, 1)), ("names", (0, 4097)), ("count", (1,)), ("count", (True,))]
    marker = object()
    monkeypatch.setitem(cap.NATIVE_FUNCTIONS, "admit_worker", lambda *args: args)
    monkeypatch.setitem(cap.NATIVE_FUNCTIONS, "_rig_edit_within_cap", lambda *args: args)
    assert cap.admit_worker(marker, "worker", 1, 2) == (marker, "worker", 1, 2)
    assert cap._rig_edit_within_cap(marker, "worker", 1) == (marker, "worker", 1)


def test_audit_cap_install_keeps_reference_and_native_callback_clones(cap, monkeypatch):
    def reference(*args):
        return args

    monkeypatch.setattr(worker_change_audit, "_names_full", reference)
    monkeypatch.setattr(worker_change_audit, "admit_worker", reference)
    monkeypatch.setattr(data_audit, "_count_policy", reference)
    monkeypatch.setattr(
        data_audit, "DataAuditMixin", SimpleNamespace(_rig_edit_within_cap=reference)
    )
    cap.install()
    assert worker_change_audit._names_full is cap._names_full
    assert worker_change_audit.admit_worker is cap.admit_worker
    assert data_audit._count_policy is cap._count_policy
    assert data_audit.DataAuditMixin._rig_edit_within_cap is cap._rig_edit_within_cap
    assert cap.NATIVE_FUNCTIONS["admit_worker"]("marker") == ("marker",)
    assert all(value is reference for value in cap.REFERENCE_FUNCTIONS.values())


@pytest.fixture
def metadata(monkeypatch):
    go_config_meta._native_plan.cache_clear()
    monkeypatch.setattr(go_config_meta, "REFERENCE_FUNCTIONS", {})
    monkeypatch.setattr(
        go_config_meta,
        "COMPAT_FUNCTIONS",
        {"parse_config_meta": lambda value: ("reference", value)},
    )
    monkeypatch.setattr(
        go_config_meta,
        "_STATE",
        {
            name: getattr(rig_config_meta, name)
            for name in ("_token", "_TOKEN_RE", "_TS_RE", "CONFIG_SOURCES")
        },
    )
    yield go_config_meta
    go_config_meta._native_plan.cache_clear()


def test_metadata_policy_uses_bounded_fields_and_caches_acceptance(metadata, monkeypatch):
    calls = []
    accepted = {"revision": True, "changed_at": False, "source": True, "last_change_id": False}
    monkeypatch.setattr(metadata.go_channel, "call", lambda *args: calls.append(args) or accepted)
    value = {
        "revision": "revision",
        "changed_at": "bad",
        "source": "wizard",
        "last_change_id": None,
    }
    expected = {
        "revision": "revision",
        "changed_at": None,
        "source": "wizard",
        "last_change_id": None,
    }
    assert metadata.parse_config_meta(value) == expected
    assert metadata.parse_config_meta(value.copy()) == expected
    assert len(calls) == 1
    assert calls[0][0] == "fleet" and calls[0][1]["operation"] == "config_meta_policy"
    fields = calls[0][1]["args"][0]
    assert fields["revision"] == {"kind": "string", "length": 8, "value": "revision"}
    assert fields["last_change_id"] == {"kind": "other"}
    assert metadata._field("x" * 65) == {"kind": "string", "length": 65}
    assert metadata._field("\ud800") is None


def test_metadata_empty_policy_and_invalid_reply(metadata, monkeypatch):
    monkeypatch.setattr(
        metadata.go_channel,
        "call",
        lambda *_args: {
            name: False for name in ("revision", "changed_at", "source", "last_change_id")
        },
    )
    assert metadata.parse_config_meta({}) is None
    metadata._native_plan.cache_clear()
    monkeypatch.setattr(metadata.go_channel, "call", lambda *_args: {"revision": 1})
    with pytest.raises(RuntimeError, match="invalid config metadata policy"):
        metadata.parse_config_meta({})


@pytest.mark.parametrize(
    "value", [None, {1: "invalid"}, {"revision": object()}, {"revision": "\ud800"}]
)
def test_metadata_noncanonical_values_use_reference_identity(metadata, value):
    assert metadata.parse_config_meta(value) == ("reference", value)


@pytest.mark.parametrize(
    "name,replacement",
    [
        ("_token", object()),
        ("_TOKEN_RE", object()),
        ("_TS_RE", object()),
        ("CONFIG_SOURCES", ()),
        ("_MAX_TOKEN_LEN", 65),
        ("str", object()),
    ],
)
def test_metadata_replaced_providers_use_reference(metadata, monkeypatch, name, replacement):
    monkeypatch.setattr(rig_config_meta, name, replacement, raising=False)
    value = {"revision": "revision"}
    assert metadata.parse_config_meta(value) == ("reference", value)


def test_metadata_install_preserves_reference_function_and_aliases(metadata, monkeypatch):
    def reference(value, *, extra=None):
        return value, extra

    reference.marker = "reference"
    monkeypatch.setattr(rig_config_meta, "parse_config_meta", reference)
    monkeypatch.setattr(xmrig_client, "parse_config_meta", reference)
    monkeypatch.setattr(worker_change_audit, "parse_config_meta", reference)
    monkeypatch.setattr(metadata, "COMPAT_FUNCTIONS", {})
    monkeypatch.setattr(metadata, "_STATE", {})
    metadata.install()
    assert rig_config_meta.parse_config_meta is metadata.parse_config_meta
    assert xmrig_client.parse_config_meta is metadata.parse_config_meta
    assert worker_change_audit.parse_config_meta is metadata.parse_config_meta
    assert metadata.COMPAT_FUNCTIONS["parse_config_meta"]("value", extra=1) == ("value", 1)
    assert metadata.COMPAT_FUNCTIONS["parse_config_meta"].marker == "reference"
