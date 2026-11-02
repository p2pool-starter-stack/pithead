from types import SimpleNamespace

import pytest

from mining_dashboard import go_preserve, go_rigforge, go_worker_detail


def rigforge_reply():
    return {
        "generated_at": "2026-01-01T00:00:00Z",
        "age_sec": 1,
        "stale": False,
        "version": "1",
        "miner_down": False,
        "power": {"watts": 10, "hs_per_watt": 2},
        "tune": {"target": None, "autotune_enabled": True, "autotune_next": None},
        "health": {
            "governor": "ok",
            "throttling": False,
            "board": "board",
            "hugepages_total": 1,
        },
        "watchdog": {"enabled": True, "thermal_hold": False, "temp_c": 50, "max_temp_c": 80},
        "config": {},
        "config_meta": {
            "revision": "r",
            "changed_at": None,
            "source": "local",
            "last_change_id": None,
        },
    }


def test_parse_rigforge_payload_and_validation(monkeypatch):
    seen = {}
    reply = rigforge_reply()
    monkeypatch.setattr(
        go_rigforge.go_channel,
        "call",
        lambda helper, payload: seen.update(helper=helper, payload=payload) or reply,
    )
    assert go_rigforge.parse_rigforge({"report": 1}, now=12) is reply
    assert seen["helper"] == "fleet"
    assert seen["payload"]["args"] == [{"report": 1}, 12]
    assert seen["payload"]["envelope"] is True
    monkeypatch.setattr(go_rigforge.go_channel, "call", lambda *_a: None)
    assert go_rigforge.parse_rigforge({}) is None


@pytest.mark.parametrize(
    "change",
    [
        lambda row: row.pop("health"),
        lambda row: row.__setitem__("stale", 1),
        lambda row: row.__setitem__("age_sec", -1),
        lambda row: row.__setitem__("config", []),
        lambda row: row.__setitem__("config_meta", {"revision": 1}),
    ],
)
def test_parse_rigforge_rejects_malformed_reply(monkeypatch, change):
    reply = rigforge_reply()
    change(reply)
    monkeypatch.setattr(go_rigforge.go_channel, "call", lambda *_a: reply)
    with pytest.raises(RuntimeError, match="native RigForge"):
        go_rigforge.parse_rigforge({})


def test_parse_rigforge_rejects_malformed_section(monkeypatch):
    reply = rigforge_reply()
    reply["power"]["extra"] = 1
    monkeypatch.setattr(go_rigforge.go_channel, "call", lambda *_a: reply)
    with pytest.raises(RuntimeError, match="invalid sections"):
        go_rigforge.parse_rigforge({})


def test_preserve_replaces_by_identity_and_forwards_native_error(monkeypatch):
    old = {"generated_at": "old", "opaque": object()}
    current = [{"name": "one", "ip": "host", "rigforge": old}]
    next_workers = [{"name": "one", "ip": "host", "rigforge": {"generated_at": "new"}}]
    monkeypatch.setattr(
        go_preserve.go_channel,
        "call",
        lambda *_a: {"replacements": [[0, 0]], "error": None},
    )
    go_preserve.preserve_newer_reports(current, next_workers)
    assert next_workers[0]["rigforge"] is old

    errors = []
    monkeypatch.setattr(
        go_preserve.go_channel,
        "call",
        lambda *_a: {
            "replacements": [],
            "error": {"kind": "TypeError", "message": "bad timestamp"},
        },
    )
    monkeypatch.setattr(go_preserve.go_channel, "response", lambda *args: errors.append(args))
    go_preserve.preserve_newer_reports(current, next_workers)
    assert errors and errors[0][0] == "fleet"


def test_preserve_rejects_wrong_identity_or_duplicate_plan(monkeypatch):
    current = [{"name": "one", "ip": "host", "rigforge": {"generated_at": "old"}}]
    next_workers = [{"name": "two", "ip": "host", "rigforge": {"generated_at": "new"}}]
    monkeypatch.setattr(
        go_preserve.go_channel,
        "call",
        lambda *_a: {"replacements": [[0, 0]], "error": None},
    )
    with pytest.raises(RuntimeError, match="invalid replacements"):
        go_preserve.preserve_newer_reports(current, next_workers)


@pytest.mark.parametrize(
    "reply",
    [
        [],
        {"replacements": "bad", "error": None},
        {"replacements": [[0, 0], [0, 0]], "error": None},
        {"replacements": [], "error": {"kind": "Other", "message": "bad"}},
    ],
)
def test_preserve_rejects_malformed_native_plans(monkeypatch, reply):
    workers = [{"name": "one", "ip": "host", "rigforge": {"generated_at": "now"}}]
    monkeypatch.setattr(go_preserve.go_channel, "call", lambda *_a: reply)
    with pytest.raises(RuntimeError, match="native report preservation"):
        go_preserve.preserve_newer_reports(workers, [dict(workers[0])])


def test_preserve_uses_replaced_age_provider_without_native_call(monkeypatch):
    from mining_dashboard.service.workers import worker_refresh

    old = {"generated_at": "b"}
    next_report = {"generated_at": "a"}
    current = [{"name": "one", "ip": "host", "rigforge": old}]
    next_workers = [{"name": "one", "ip": "host", "rigforge": next_report}]
    monkeypatch.setattr(worker_refresh, "feed_age", lambda value: 1 if value else None)
    monkeypatch.setattr(
        go_preserve.go_channel,
        "call",
        lambda *_a: (_ for _ in ()).throw(AssertionError("native called")),
    )
    go_preserve.preserve_newer_reports(current, next_workers)
    assert next_workers[0]["rigforge"] is old


def test_worker_detail_run_wraps_native_failure(monkeypatch):
    monkeypatch.setattr(
        go_worker_detail.go_channel,
        "call",
        lambda *_a, **_kw: (_ for _ in ()).throw(RuntimeError("down")),
    )
    with pytest.raises(RuntimeError, match="native worker detail unavailable"):
        go_worker_detail.config_origin({}, False)


def test_capture_returns_isolated_worker_snapshot(monkeypatch):
    monkeypatch.setattr(go_worker_detail.time, "time", lambda: 11)
    source = {
        "timestamp": 8,
        "rigforge_release": {"v": 1},
        "workers": [{"name": "one", "nested": {"x": 1}}, {"name": "two"}],
    }
    captured, now = go_worker_detail.capture("one", source)
    assert now == 11
    assert captured["workers"] == [{"name": "one", "nested": {"x": 1}}]
    assert captured["workers"][0] is not source["workers"][0]
    assert go_worker_detail.capture("missing", source)[0]["workers"] == []


def test_worker_hashrate_history_payload(monkeypatch):
    state = SimpleNamespace(
        get_worker_history=lambda **kwargs: [[kwargs["name"]]],
        get_worker_config_history=lambda name, limit: [[name, limit]],
    )
    monkeypatch.setattr(go_worker_detail, "_run", lambda op, args, **_kw: (op, args))
    operation, args = go_worker_detail.build_worker_hashrate_history(
        state, "one", "day", window=(1, 2)
    )
    assert operation == "build_worker_hashrate_history"
    assert args == [[["one"]], [["one", 200]], "day", (1, 2)]


def test_build_prepared_validates_result_shape(monkeypatch):
    monkeypatch.setattr(go_worker_detail, "_run", lambda *_a, **_kw: {})
    with pytest.raises(RuntimeError, match="invalid native worker detail result"):
        go_worker_detail.build_prepared({"now": 1})
