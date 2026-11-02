from types import SimpleNamespace

import pytest

from mining_dashboard import go_polling


def test_run_builds_fleet_envelope(monkeypatch):
    seen = {}
    monkeypatch.setattr(
        go_polling.go_channel,
        "call",
        lambda helper, payload: seen.update(helper=helper, payload=payload) or {"ok": True},
    )
    assert go_polling._run("sample", [1], now=7) == {"ok": True}
    assert seen == {
        "helper": "fleet",
        "payload": {"operation": "poll_sample", "args": [1], "now": 7, "envelope": True},
    }


def test_merge_proxy_summary_adopts_or_preserves_identity(monkeypatch):
    old = {"old": True}
    monkeypatch.setattr(go_polling, "_run", lambda *_a: {"adopt": False, "summary": None})
    assert go_polling._merge_proxy_summary(old, {}) is old
    fresh = {"new": True}
    monkeypatch.setattr(go_polling, "_run", lambda *_a: {"adopt": True, "summary": fresh})
    assert go_polling._merge_proxy_summary(old, {}) is fresh
    monkeypatch.setattr(go_polling, "_run", lambda *_a: {"adopt": True, "summary": []})
    with pytest.raises(RuntimeError, match="invalid data"):
        go_polling._merge_proxy_summary(old, {})


def test_patches_and_aggregate_contracts(monkeypatch):
    assert go_polling._patches([{"uptime": 1}], 1, {"uptime"}) == [{"uptime": 1}]
    with pytest.raises(RuntimeError, match="invalid patches"):
        go_polling._patches([{"other": 1}], 1, {"uptime"})
    monkeypatch.setattr(go_polling, "_run", lambda operation, args, **_kw: [1, 2])
    assert go_polling._aggregate_hashrate([{}]) == (1, 2)
    assert go_polling._summary_deltas({}, {"x": 1}) == (1, {"x": 1})
    assert go_polling._shares_to_record(1, 2) == (1, 2)


def test_polling_parse_helpers_forward_clock_and_config(monkeypatch):
    calls = []
    monkeypatch.setattr(
        go_polling,
        "_run",
        lambda operation, args, **kwargs: calls.append((operation, args, kwargs)) or {"ok": True},
    )
    assert go_polling._parse_proxy_list_worker({"name": "one"}, now=5) == {"ok": True}
    assert go_polling._parse_legacy_dict_worker({"name": "one"}) == {"ok": True}
    assert go_polling._normalize_proxy_workers([], now=6) == {"ok": True}
    assert go_polling._parse_proxy_summary({}) == {"ok": True}
    assert calls[0][0] == "parse_proxy_list_worker"
    assert calls[0][2] == {"now": 5}
    assert calls[2][2] == {"now": 6}


def test_merge_direct_stats_applies_patches(monkeypatch):
    from mining_dashboard.service import data_helpers

    monkeypatch.setattr(data_helpers, "parse_rigforge", lambda row: {"parsed": row})
    monkeypatch.setattr(
        go_polling,
        "_run",
        lambda operation, args: [{"api_ok": True, "h10": 4}],
    )
    worker = {"name": "one"}
    result = go_polling._merge_direct_stats([worker], [{"raw": 1}], 3333)
    assert result == [{"name": "one", "api_ok": True, "h10": 4}]
    assert result[0] is worker


def test_lifecycle_update_mutates_workers_and_reuses_state(monkeypatch):
    existing = {"connected_since": 1, "last_active": 2}
    owner = SimpleNamespace(_state={"a": existing}, falloff_sec=30)
    reply = {
        "patches": [{"uptime": 9}, {"uptime": None}],
        "live_indices": [0],
        "state": [["a", {"connected_since": 3, "last_active": 4}]],
    }
    monkeypatch.setattr(go_polling, "_run", lambda *_a, **_kw: reply)
    workers = [{"name": "a"}, {"name": "b"}]
    result = go_polling.lifecycle_update(owner, workers, 10)
    assert result == [{"name": "a", "uptime": 9}]
    assert owner._state["a"] is existing
    assert existing == {"connected_since": 3, "last_active": 4}


@pytest.mark.parametrize(
    "reply",
    [
        {},
        {"patches": [], "live_indices": [], "state": []},
        {"patches": [{}], "live_indices": [2], "state": []},
        {
            "patches": [{}],
            "live_indices": [],
            "state": [["a", {"connected_since": 1}]],
        },
    ],
)
def test_lifecycle_update_rejects_malformed_reply(monkeypatch, reply):
    owner = SimpleNamespace(_state={}, falloff_sec=1)
    monkeypatch.setattr(go_polling, "_run", lambda *_a, **_kw: reply)
    with pytest.raises(RuntimeError):
        go_polling.lifecycle_update(owner, [{}], 0)


@pytest.mark.asyncio
async def test_probe_preserves_alignment_and_updates_answered(monkeypatch):
    replies = iter(
        [
            [True, False],
            {"result_indices": [0, None], "answered": [["one", "ip"]]},
        ]
    )
    monkeypatch.setattr(go_polling, "_run", lambda *_a, **_kw: next(replies))

    async def stats(ip, name):
        return {"ip": ip, "name": name}

    owner = SimpleNamespace(_answered=set())
    client = SimpleNamespace(get_stats=stats)
    result = await go_polling.probe(
        owner,
        client,
        [{"name": "one", "ip": "host", "extra": 1}, {"name": "two", "ip": "peer"}],
    )
    assert result == [{"ip": "host", "name": "one"}, {}]
    assert owner._answered == {("one", "ip")}


@pytest.mark.asyncio
async def test_probe_rejects_invalid_plan(monkeypatch):
    monkeypatch.setattr(go_polling, "_run", lambda *_a, **_kw: [True])
    with pytest.raises(RuntimeError, match="invalid plan"):
        await go_polling.probe(
            SimpleNamespace(_answered=set()),
            SimpleNamespace(get_stats=None),
            [{"name": "one", "ip": "host"}, {"name": "two", "ip": "peer"}],
        )
