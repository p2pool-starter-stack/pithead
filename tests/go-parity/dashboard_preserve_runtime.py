import os

import pytest

from mining_dashboard import go_preserve
from mining_dashboard.service.workers import worker_refresh

# ruff: noqa: S101

pytestmark = pytest.mark.skipif(
    os.environ.get("PITHEAD_IMPL") != "go", reason="Go dashboard parity only"
)


def _fleet(size):
    current = []
    following = []
    for index in range(size):
        old = {"generated_at": "2026-09-29T22:01:00Z", "opaque": object()}
        new = {"generated_at": "2026-09-29T22:00:30Z", "index": index}
        current.append(
            {"name": f"rig-{index}", "ip": f"192.0.2.{index % 200 + 1}", "rigforge": old}
        )
        following.append(
            {"name": f"rig-{index}", "ip": f"192.0.2.{index % 200 + 1}", "rigforge": new}
        )
    return current, following


def test_large_fleet_uses_one_native_call_and_keeps_report_identity(monkeypatch):
    calls = []
    clocks = []
    native_call = go_preserve.go_channel.call

    def counted(helper, payload):
        calls.append((helper, payload["operation"]))
        return native_call(helper, payload)

    monkeypatch.setattr(go_preserve.go_channel, "call", counted)
    monkeypatch.setattr(
        go_preserve.rigforge_freshness.time,
        "time",
        lambda: clocks.append(1_800_000_000) or 1_800_000_000,
    )
    current, following = _fleet(1000)
    identities = [worker["rigforge"] for worker in current]
    assert worker_refresh.preserve_newer_reports(current, following) is None
    assert calls == [("fleet", "poll_preserve_reports")]
    assert clocks == [1_800_000_000]
    assert all(
        worker["rigforge"] is report for worker, report in zip(following, identities, strict=True)
    )


def test_retained_report_uses_the_same_snapshot_as_its_selection(monkeypatch):
    current, following = _fleet(1)
    old = current[0]["rigforge"]
    replacement = {"generated_at": "2026-09-29T22:02:00Z", "opaque": object()}
    native_call = go_preserve.go_channel.call

    def interleaved(helper, payload):
        result = native_call(helper, payload)
        current[0]["rigforge"] = replacement
        return result

    monkeypatch.setattr(go_preserve.go_channel, "call", interleaved)
    worker_refresh.preserve_newer_reports(current, following)
    assert following[0]["rigforge"] is old
    assert current[0]["rigforge"] is replacement


@pytest.mark.parametrize(
    "reply",
    [
        None,
        [],
        {},
        {"replacements": None, "error": None},
        {"replacements": [[True, 0]], "error": None},
        {"replacements": [[0, 0], [1, 99]], "error": None},
        {"replacements": [[0, 1]], "error": None},
        {"replacements": [[0, 0], [0, 1]], "error": None},
        {"replacements": [[0, 0]], "error": {"kind": "KeyError", "message": "bad"}},
        {"replacements": [[0, 0]], "error": {"kind": "TypeError", "message": 1}},
    ],
)
def test_invalid_native_plan_fails_before_partial_mutation(monkeypatch, reply):
    current, following = _fleet(2)
    identities = [worker["rigforge"] for worker in following]
    monkeypatch.setattr(go_preserve.go_channel, "call", lambda *_args, **_kwargs: reply)
    with pytest.raises(RuntimeError, match="invalid"):
        worker_refresh.preserve_newer_reports(current, following)
    assert all(
        worker["rigforge"] is report for worker, report in zip(following, identities, strict=True)
    )


def test_semantic_error_applies_only_the_completed_prefix():
    current, following = _fleet(2)
    invalid = ["invalid"]
    following[1]["rigforge"] = invalid
    with pytest.raises(AttributeError, match="'list' object has no attribute 'get'"):
        worker_refresh.preserve_newer_reports(current, following)
    assert following[0]["rigforge"] is current[0]["rigforge"]
    assert following[1]["rigforge"] is invalid


def test_interposed_age_provider_uses_explicit_compatibility(monkeypatch):
    calls = []
    current, following = _fleet(2)
    current[1]["rigforge"] = None

    def age(stamp):
        calls.append(stamp)
        return None if stamp.endswith("30Z") else 0

    def unavailable(*_args, **_kwargs):
        raise AssertionError("interposed provider used the native helper")

    monkeypatch.setattr(worker_refresh, "feed_age", age)
    monkeypatch.setattr(go_preserve.go_channel, "call", unavailable)
    worker_refresh.preserve_newer_reports(current, following)
    assert calls == ["2026-09-29T22:01:00Z", "2026-09-29T22:00:30Z"]
    assert following[0]["rigforge"] is current[0]["rigforge"]
    assert following[1]["rigforge"]["index"] == 1
