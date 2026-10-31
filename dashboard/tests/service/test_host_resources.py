import math

import pytest

from mining_dashboard.service.host_resources import build_host_resources

NOW = 1_800_000_000
GIB = 1024**3


def samples(now=NOW, total=500, used=123):
    return {
        "cpu": {"sampled_at": now, "value": 0},
        "load": {"sampled_at": now, "value": [0, 0.5, 1.5]},
        "memory": {
            "sampled_at": now,
            "value": {"total": 4 * GIB, "used": GIB, "available": 3 * GIB},
        },
        "filesystem": {"sampled_at": now, "value": {"total": total * GIB, "used": used * GIB}},
        "hugepages": {"sampled_at": now, "value": {"total": 0, "used": 0, "free": 0}},
    }


def history(count=24, interval=3600, end=NOW, used=100, step=1, total=500):
    return [
        {
            "ts": end - (count - i - 1) * interval,
            "disk_used_gb": used + i * step,
            "disk_total_gb": total,
            "monero_db_bytes": i * GIB,
        }
        for i in range(count)
    ]


def outlook(rows=None, **kwargs):
    return build_host_resources(samples(**kwargs), history() if rows is None else rows, NOW)[
        "capacity_outlook"
    ]


def test_resource_units_zero_values_and_unsupported_capabilities():
    result = build_host_resources(samples(), [], NOW + 10)
    for name in ("cpu", "load", "memory", "filesystem", "hugepages"):
        assert result[name]["state"] == "available"
        assert result[name]["age_seconds"] == 10
    assert result["cpu"]["value"] == 0
    assert result["memory"]["unit"] == "bytes"
    assert result["filesystem"]["value"]["total"] == 500 * GIB
    assert result["load"]["value"] == [0, 0.5, 1.5]
    assert result["hugepages"]["unit"] == "pages"
    for name in ("swap", "temperature", "smart", "io_latency", "containers"):
        assert result[name]["state"] == "unavailable"
        assert result[name]["reason"] == "unsupported"
        assert result[name]["value"] is None
        assert result[name]["sampled_at"] is None


@pytest.mark.parametrize("offset,reason", [(10000, "stale"), (-1, "clock_changed")])
def test_clock_changes_never_present_samples_as_live(offset, reason):
    result = build_host_resources(samples(), history(), NOW + offset)
    assert result["memory"]["state"] == "unavailable"
    assert result["memory"]["reason"] == reason
    assert result["memory"]["value"] is None
    assert result["capacity_outlook"]["state"] == "unavailable"


def test_legacy_snapshot_without_metadata_is_unavailable():
    result = build_host_resources({}, history(), NOW)
    assert result["cpu"]["reason"] == "missing"
    assert result["cpu"]["sampled_at"] is None
    assert result["cpu"]["age_seconds"] is None
    assert result["cpu"]["value"] is None


@pytest.mark.parametrize("value", [None, math.nan, math.inf, -1, 101, True, "50%"])
def test_invalid_cpu_values_have_no_live_value(value):
    data = samples()
    data["cpu"]["value"] = value
    assert build_host_resources(data, [], NOW)["cpu"]["value"] is None


def test_capacity_estimate_reports_its_actual_basis():
    result = outlook()
    assert result["state"] == "estimated"
    assert result["sample_count"] == 24
    assert result["window_seconds"] == 7 * 86400
    assert result["from"] == NOW - 23 * 3600
    assert result["to"] == NOW
    assert result["growth_bytes_per_day"] == 24 * GIB
    assert result["days_remaining"] == pytest.approx((500 - 123) / 24)


@pytest.mark.parametrize("rows", [[], history(23), history(24, interval=60)])
def test_insufficient_history_has_no_countdown(rows):
    result = outlook(rows)
    assert result["state"] == "insufficient_history"
    assert result["days_remaining"] is None


def test_missing_hours_use_elapsed_time_not_zero_growth():
    rows = history(25, interval=7200)
    result = outlook(rows, used=124)
    assert result["state"] == "estimated"
    assert result["growth_bytes_per_day"] == 12 * GIB


def test_long_gap_requires_a_new_history_segment():
    rows = history(24, end=NOW - 5 * 3600) + history(1, used=124)
    result = outlook(rows, used=124)
    assert result["state"] == "insufficient_history"
    assert result["sample_count"] == 1


@pytest.mark.parametrize("field,value", [("disk_used_gb", 0), ("disk_total_gb", 600)])
def test_usage_reset_or_resize_requires_new_history(field, value):
    rows = history()
    rows[-1][field] = value
    result = outlook(rows, total=600 if field == "disk_total_gb" else 500)
    assert result["state"] == "insufficient_history"
    assert result["sample_count"] == 1


def test_current_resize_and_replacement_invalidate_old_estimate():
    assert outlook(total=600)["reason"] == "capacity_changed"
    assert outlook(used=10)["reason"] == "usage_reset"
    result = outlook(history(48, total=600), total=600, used=147)
    assert result["state"] == "estimated"


def test_missing_reads_in_history_are_not_zero_growth():
    rows = history()
    rows[-2].update(disk_used_gb=0, disk_total_gb=0)
    result = outlook(rows)
    assert result["state"] == "insufficient_history"
    assert result["sample_count"] == 1


def test_future_and_duplicate_timestamps_cannot_produce_estimate():
    rows = history()
    rows[-1]["ts"] = NOW + 1
    assert outlook(rows)["reason"] == "clock_changed"
    rows[-1]["ts"] = rows[-2]["ts"]
    assert outlook(rows)["sample_count"] == 1


def test_stale_disk_history_has_no_countdown():
    result = outlook(history(end=NOW - 4 * 3600))
    assert result["reason"] == "stale_history"
    assert result["days_remaining"] is None


def test_zero_growth_has_no_infinite_or_guaranteed_countdown():
    result = outlook(history(step=0))
    assert result["state"] == "no_growth"
    assert result["days_remaining"] is None


def test_outlook_is_bounded_to_169_rows_and_seven_days():
    rows = history(10000, used=0, step=0.01)
    result = outlook(rows, used=100)
    assert result["state"] == "estimated"
    assert result["sample_count"] == 169
    assert result["to"] - result["from"] == 7 * 86400
    rows = history(169, interval=7200, used=0)
    assert outlook(rows, used=168)["sample_count"] == 85


@pytest.mark.parametrize(
    "metadata", [None, {"cpu": None}, {"cpu": {"sampled_at": float("nan"), "value": 10}}]
)
def test_malformed_sample_metadata_is_unavailable(metadata):
    result = build_host_resources(metadata, [], NOW)
    assert result["cpu"]["state"] == "unavailable"
    assert result["cpu"]["value"] is None


@pytest.mark.parametrize(
    "name,value",
    [
        ("load", [1, 2]),
        ("load", [1, float("nan"), 3]),
        ("memory", None),
        ("memory", {"total": 10, "used": 20, "available": 1}),
        ("filesystem", {"total": 0, "used": 0}),
        ("hugepages", {"total": -1, "used": 0}),
    ],
)
def test_invalid_resources_are_unavailable(name, value):
    data = samples()
    data[name]["value"] = value
    result = build_host_resources(data, [], NOW)
    assert result[name]["state"] == "unavailable"
    assert result[name]["value"] is None


@pytest.mark.parametrize(
    "key,value", [("ts", float("nan")), ("disk_used_gb", -1), ("disk_total_gb", None)]
)
def test_invalid_historical_sample_starts_a_new_segment(key, value):
    rows = history()
    rows[-2][key] = value
    assert outlook(rows)["sample_count"] == 1


@pytest.mark.parametrize(
    "name,value",
    [
        ("memory", {"total": 100, "used": 25, "available": 100}),
        ("hugepages", {"total": 10, "used": 5}),
        ("hugepages", {"total": 10, "used": 5, "free": 10}),
    ],
)
def test_inconsistent_snapshot_cannot_be_presented_as_live(name, value):
    data = samples()
    data[name]["value"] = value
    result = build_host_resources(data, [], NOW)
    assert result[name]["reason"] == "invalid_sample"
    assert result[name]["value"] is None
