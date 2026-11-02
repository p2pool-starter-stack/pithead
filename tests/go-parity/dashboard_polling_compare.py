import copy
import math

import dashboard_polling_plugin as adapter
import pytest

from mining_dashboard.service import data_helpers
from mining_dashboard.service.worker_probe import WorkerProber

# ruff: noqa: S101

pytest_plugins = ["dashboard_polling_plugin"]


def _same(left, right):
    if isinstance(left, float) and math.isnan(left):
        assert isinstance(right, float) and math.isnan(right)
        return
    if isinstance(left, dict):
        assert left.keys() == right.keys()
        for key in left:
            _same(left[key], right[key])
        return
    if isinstance(left, (list, tuple)):
        assert type(left) is type(right)
        assert len(left) == len(right)
        for a, b in zip(left, right, strict=True):
            _same(a, b)
        return
    assert left == right
    if not isinstance(left, (int, float)) or isinstance(left, bool):
        assert type(left) is type(right)


def _paired(operation, *args, **kwargs):
    reference = adapter.python_call(operation, *copy.deepcopy(args), **copy.deepcopy(kwargs))
    native = getattr(data_helpers, operation)(*copy.deepcopy(args), **copy.deepcopy(kwargs))
    _same(reference, native)
    return native


@pytest.mark.parametrize(
    ("row", "now"),
    [
        (["rig", "rig.example.com", 1, 7, 2, 1, 0, 0, 1.25, 2.5, 3, 4, 5], 2000.0),
        (["rig", "rig.example.com", 0, 7, 0, 0, 0, 1_970_000, 0, 0, 0, 0, 0], 2000.0),
        (["rig", "rig.example.com", 0, 7, 0, 0, 0, 1_969_999, 0, 0, 0, 0, 0], 2000.0),
        (["rig", "rig.example.com", 1, 1, 0, 0, 0, 0, math.nan, 2, 3, 4, 5], 2000.0),
    ],
)
def test_proxy_list_parser_matches_thresholds_and_rates(row, now):
    _paired("_parse_proxy_list_worker", row, now=now)


@pytest.mark.parametrize(
    "row",
    [
        {},
        {"id": "old", "ip": "old.example.com", "hashrate": []},
        {"id": "old", "hashrate": [1]},
        {"id": "old", "hashrate": [1, 2], "accepted": 2**60 + 3},
        {"id": "old", "hashrate": [1, 2, 3, 4], "uptime": 2**60 + 5},
    ],
)
def test_legacy_parser_matches_sparse_and_wide_values(row):
    _paired("_parse_legacy_dict_worker", row)


def test_normalizer_matches_mixed_shapes_without_mutating_input():
    payload = {
        "workers": [
            ["rig", "rig.example.com", 1, 1, 0, 0, 0, 0, 1, 2, 3, 4, 5],
            ["short", "short.example.com"],
            {"id": "old", "ip": "old.example.com", "hashrate": [4, 5, 6]},
            "ignored",
        ]
    }
    before = copy.deepcopy(payload)
    result = _paired("_normalize_proxy_workers", payload, now=1234.0)
    assert [row["name"] for row in result] == ["rig", "old"]
    assert payload == before


@pytest.mark.parametrize("payload", [None, {}, {"workers": []}])
def test_normalizer_matches_empty_payloads(payload):
    _paired("_normalize_proxy_workers", payload, now=1234.0)


def test_normalizer_matches_missing_workers_error():
    with pytest.raises(ValueError) as reference:
        adapter.python_call("_normalize_proxy_workers", {"version": "6.x"}, now=1.0)
    with pytest.raises(ValueError) as native:
        data_helpers._normalize_proxy_workers({"version": "6.x"}, now=1.0)
    assert str(native.value) == str(reference.value)


@pytest.mark.parametrize("last,current", [(float(10**23), 10**23), (10**23, float(10**23))])
def test_share_comparison_keeps_binary_float_integer_order(last, current):
    _paired("_shares_to_record", last, current)


def test_summary_reset_compares_binary_float_against_wide_integer():
    last = {"accepted": 10**23, "rejected": 0, "invalid": 0, "expired": 0}
    current = {**last, "accepted": float(10**23), "rejected": 1}
    _paired("_summary_deltas", last, current)


@pytest.mark.parametrize(
    "payload",
    [
        None,
        "bad",
        {"version": "6.x"},
        {"results": {"accepted": 2**60 + 1, "best": [2**60 + 7]}},
    ],
)
def test_summary_parser_matches(payload):
    _paired("_parse_proxy_summary", payload)


def test_summary_merge_matches_valid_zero_and_malformed_hold():
    last = {"accepted": 9, "rejected": 2, "invalid": 1, "expired": 0, "best": 8}
    _paired("_merge_proxy_summary", last, None)
    _paired("_merge_proxy_summary", last, {"version": "6.x"})


def _worker(name="rig", status="online"):
    return {
        "name": name,
        "ip": f"{name}.example.com",
        "status": status,
        "h10": 1,
        "h60": 2,
        "h15": 3,
        "h1h": 4,
        "h12h": 5,
        "h24h": 6,
        "uptime": 0,
    }


def test_direct_stats_matches_alignment_flags_scaling_and_identity():
    workers = [_worker("a"), _worker("b"), _worker("unpaired")]
    results = [
        {
            "api_ok": True,
            "adopted": True,
            "kind": "proxy",
            "uptime": 90,
            "hashrate": {"total": [1.5, 2.5, 3.5]},
        },
        {"api_ok": False, "adopted": False},
    ]
    ref_workers = copy.deepcopy(workers)
    native_workers = copy.deepcopy(workers)
    reference = adapter.python_call(
        "_merge_direct_stats", ref_workers, copy.deepcopy(results), "3333"
    )
    native = data_helpers._merge_direct_stats(native_workers, copy.deepcopy(results), "3333")
    _same(reference, native)
    assert all(row is source for row, source in zip(native, native_workers, strict=False))
    assert len(native) == 2
    assert native[0]["h15"] == 3500
    assert native[1]["api_ok"] is False


def test_direct_stats_keeps_python_rigforge_parse(monkeypatch):
    calls = []

    def parse(value):
        calls.append(value)
        return {"model": "Example"}

    monkeypatch.setattr(data_helpers, "parse_rigforge", parse)
    result = _paired(
        "_merge_direct_stats", [_worker()], [{"api_ok": False, "feed": "enriched"}], "4444"
    )
    assert calls == [{"api_ok": False, "feed": "enriched"}] * 2
    assert result[0]["rigforge"] == {"model": "Example"}


@pytest.mark.parametrize(
    ("kind", "rates"),
    [("miner", [0.1, 0.2, 0.3]), ("proxy", [0.0003, 0.0007, 0.0011])],
)
def test_direct_stats_matches_ieee_fractional_rates(kind, rates):
    extra = {"api_ok": True, "kind": kind, "hashrate": {"total": rates}}
    _paired("_merge_direct_stats", [_worker()], [extra], "5555")


def test_hashrate_aggregates_match_fallbacks_windows_and_wide_values():
    workers = [
        {**_worker("a"), "h15": 0, "h60": 7, "h10": 2**60 + 1},
        {**_worker("b"), "h15": 2**60 + 3, "h10": 5},
        {**_worker("off", "offline"), "h15": 2**62},
    ]
    _paired("_aggregate_hashrate", workers)
    _paired("_aggregate_window_hashrates", workers)


def test_hashrate_aggregate_preserves_python_ieee_addition():
    workers = [{**_worker(str(index)), "h15": 0.1} for index in range(3)]
    result = _paired("_aggregate_hashrate", workers)
    assert result[0] == 0.1 + 0.1 + 0.1


@pytest.mark.parametrize(
    ("last", "current"),
    [
        (None, {"accepted": 2**60, "rejected": 0, "invalid": 0, "expired": 0}),
        (
            {"accepted": 2**60, "rejected": 2, "invalid": 1, "expired": 0},
            {"accepted": 2**60 + 9, "rejected": 3, "invalid": 1, "expired": 4},
        ),
        (
            {"accepted": 10, "rejected": 2, "invalid": 1, "expired": 0},
            {"accepted": 9, "rejected": 3, "invalid": 1, "expired": 0},
        ),
        (
            {"accepted": 0.1, "rejected": 0, "invalid": 0, "expired": 0},
            {"accepted": 0.3, "rejected": 0, "invalid": 0, "expired": 0},
        ),
    ],
)
def test_summary_deltas_match_wide_reset_and_baseline(last, current):
    _paired("_summary_deltas", last, current)


@pytest.mark.parametrize(
    ("last", "current"),
    [(None, 2**60), (2**60, 2**60 + 11), (100, 3), (5, 5)],
)
def test_share_recording_matches_wide_and_reset_values(last, current):
    _paired("_shares_to_record", last, current)


def test_lifecycle_matches_identity_state_and_stale_ghost_policy():
    reference = data_helpers.WorkerLifecycle(10)
    native = data_helpers.WorkerLifecycle(10)
    sequence = [
        (100.0, [_worker("rig")]),
        (105.0, [_worker("rig")]),
        (106.0, [_worker("rig", "offline")]),
        (111.0, [_worker("rig", "offline")]),
        (117.0, [_worker("rig", "offline")]),
        (200.0, [_worker("rig", "offline")]),
        (201.0, [_worker("rig")]),
        (202.0, []),
    ]
    for now, rows in sequence:
        reference_rows = copy.deepcopy(rows)
        native_rows = copy.deepcopy(rows)
        expected = adapter.python_call("WorkerLifecycle.update", reference, reference_rows, now)
        actual = native.update(native_rows, now)
        _same(expected, actual)
        assert all(row is source for row, source in zip(actual, native_rows, strict=False))
        _same(reference._state, native._state)


def test_lifecycle_filtered_result_keeps_selected_worker_identity():
    reference = data_helpers.WorkerLifecycle(10)
    native = data_helpers.WorkerLifecycle(10)
    adapter.python_call("WorkerLifecycle.update", reference, [_worker("gone")], 100.0)
    native.update([_worker("gone")], 100.0)
    reference_rows = [_worker("gone", "offline"), _worker("kept")]
    native_rows = copy.deepcopy(reference_rows)
    expected = adapter.python_call("WorkerLifecycle.update", reference, reference_rows, 111.0)
    actual = native.update(native_rows, 111.0)
    _same(expected, actual)
    assert actual == [native_rows[1]]
    assert actual[0] is native_rows[1]


def test_lifecycle_matches_huge_finite_uptime():
    reference = data_helpers.WorkerLifecycle(10)
    native = data_helpers.WorkerLifecycle(10)
    adapter.python_call("WorkerLifecycle.update", reference, [_worker()], 0.0)
    native.update([_worker()], 0.0)
    expected = adapter.python_call("WorkerLifecycle.update", reference, [_worker()], 1e30)
    actual = native.update([_worker()], 1e30)
    _same(expected, actual)
    assert actual[0]["uptime"] == int(1e30)


class _Client:
    def __init__(self, answers):
        self.answers = answers
        self.probed = []

    async def get_stats(self, ip, name):
        self.probed.append((ip, name))
        return self.answers.get(name, {"api_ok": False, "adopted": False})


@pytest.mark.asyncio
async def test_prober_matches_alignment_result_identity_and_answered_policy():
    reference = WorkerProber()
    native = WorkerProber()
    steps = [
        [_worker("a"), _worker("ghost", "offline"), _worker("c")],
        [_worker("a", "offline"), _worker("ghost", "offline"), _worker("c", "offline")],
        [{**_worker("a", "offline"), "ip": "changed.example.com"}],
    ]
    answers = {
        "a": {"api_ok": True, "token": "a"},
        "c": {"api_ok": True, "token": "c"},
    }
    for workers in steps:
        ref_client = _Client(answers)
        native_client = _Client(answers)
        expected = await adapter.python_async_call(
            "WorkerProber.probe", reference, ref_client, copy.deepcopy(workers)
        )
        actual = await native.probe(native_client, copy.deepcopy(workers))
        assert [row.get("api_ok") for row in expected] == [row.get("api_ok") for row in actual]
        assert ref_client.probed == native_client.probed
        assert reference._answered == native._answered
        for row in actual:
            if row.get("api_ok"):
                assert any(row is answer for answer in answers.values())
