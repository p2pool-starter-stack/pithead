import copy
import json
import os
from datetime import UTC, datetime

import pytest

from mining_dashboard import go_channel, go_polling, go_rigforge
from mining_dashboard.client import rigforge_freshness

# ruff: noqa: S101

pytestmark = pytest.mark.skipif(
    os.environ.get("PITHEAD_IMPL") != "go", reason="Go dashboard parity only"
)


def reply():
    return {
        "generated_at": None,
        "age_sec": None,
        "stale": True,
        "version": None,
        "miner_down": False,
        "power": {"watts": None, "hs_per_watt": None},
        "tune": {"target": None, "autotune_enabled": False, "autotune_next": None},
        "health": {"governor": None, "throttling": None, "board": None, "hugepages_total": None},
        "watchdog": {"enabled": False, "thermal_hold": None, "temp_c": None, "max_temp_c": None},
        "config": None,
        "config_meta": None,
    }


@pytest.mark.parametrize(
    "field,value",
    [
        ("extra", True),
        ("power", {}),
        ("watchdog", []),
        ("stale", 1),
        ("generated_at", 1),
        ("age_sec", False),
        ("age_sec", -1),
        ("config", []),
        ("config", {"ACCESS_TOKEN": "example-token"}),
        ("config_meta", {}),
        (
            "config_meta",
            {"revision": 1, "source": None, "last_change_id": None, "changed_at": None},
        ),
    ],
)
def test_malformed_parser_reply_fails_closed(monkeypatch, field, value):
    parsed = reply()
    parsed[field] = value
    monkeypatch.setattr(go_channel, "call", lambda *_args, **_kwargs: parsed)
    with pytest.raises(RuntimeError, match="native RigForge parser returned invalid"):
        go_rigforge.parse_rigforge({"rigforge": {}}, now=0)


def test_missing_fields_and_helper_failure_do_not_fall_back(monkeypatch):
    parsed = reply()
    del parsed["config"]
    monkeypatch.setattr(go_channel, "call", lambda *_args, **_kwargs: parsed)
    with pytest.raises(RuntimeError, match="native RigForge parser returned invalid"):
        go_rigforge.parse_rigforge({"rigforge": {}}, now=0)

    def unavailable(*_args, **_kwargs):
        raise RuntimeError("helper unavailable")

    monkeypatch.setattr(go_channel, "call", unavailable)
    with pytest.raises(RuntimeError, match="helper unavailable"):
        go_rigforge.parse_rigforge({"rigforge": {}}, now=0)


@pytest.mark.parametrize("kind", ["AttributeError", "OverflowError"])
def test_native_parser_exception_kind_is_preserved(kind):
    expected = AttributeError if kind == "AttributeError" else OverflowError
    with pytest.raises(expected, match="native failure"):
        go_channel.response(
            "fleet", json.dumps({"ok": False, "error": {"kind": kind, "message": "native failure"}})
        )


def test_default_clock_is_captured_once_and_explicit_clock_is_retained(monkeypatch):
    clocks, sent = [], []

    def now():
        clocks.append(1234)
        return 1234

    def capture(_helper, payload):
        sent.append(payload["args"][1])
        return None

    monkeypatch.setattr(rigforge_freshness.time, "time", now)
    monkeypatch.setattr(go_channel, "call", capture)
    go_rigforge.parse_rigforge({"rigforge": {}})
    go_rigforge.parse_rigforge({"rigforge": {}}, now=0)
    assert clocks == [1234]
    assert sent == [1234, 0]


def enriched():
    return {
        "generated_at": "2026-09-07T05:00:00Z",
        "rigforge": {
            "version": "1.0.0",
            "config": {"pools": [{"url": "example.com:3333", "pass": "example-password"}]},
        },
        "hashrate": {"total": [100, 90, 80]},
        "uptime": 42,
        "connection": {"pool": "example.com:3333"},
    }


def test_large_fleet_uses_one_native_parse_and_merge_call(monkeypatch):
    calls = []
    native_call = go_channel.call

    def counted(helper, payload):
        calls.append((helper, payload["operation"]))
        return native_call(helper, payload)

    now = datetime(2026, 9, 7, 5, tzinfo=UTC).timestamp() + 30
    monkeypatch.setattr(rigforge_freshness.time, "time", lambda: now)
    monkeypatch.setattr(go_channel, "call", counted)
    workers = [{"name": f"worker-{index}", "online": True} for index in range(1000)]
    results = [enriched() for _ in workers]
    original_results = copy.deepcopy(results)
    output = go_polling._merge_direct_stats(workers, results, 3333)
    assert calls == [("fleet", "poll_merge_rigforge_stats")]
    assert all(row is worker for row, worker in zip(output, workers, strict=True))
    assert all(row["rigforge"]["age_sec"] == 30 for row in output)
    assert all(
        row["rigforge"]["config"]["pools"][0]["pass"] == {"__secret__": True} for row in output
    )
    assert results == original_results


def test_combined_parse_failure_keeps_all_workers_unchanged():
    workers = [{"name": "first", "online": True}, {"name": "second", "online": True}]
    before = copy.deepcopy(workers)
    broken = enriched()
    broken["rigforge"]["power"] = [1]
    with pytest.raises(AttributeError):
        go_polling._merge_direct_stats(workers, [enriched(), broken], 3333)
    assert workers == before
