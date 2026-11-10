import math
import time

from mining_dashboard.config.config import UPDATE_INTERVAL

_GIB = 1024**3
_MAX_AGE = max(60, 3 * UPDATE_INTERVAL)
_WINDOW = 7 * 86400
_MAX_ROWS = 169
_MIN_SAMPLES = 24
_MAX_GAP = 3 * 3600
_RESOURCES = {
    "cpu": ("percent", "proc_stat"),
    "load": ("runnable_or_waiting_tasks", "getloadavg"),
    "memory": ("bytes", "proc_meminfo"),
    "filesystem": ("bytes", "data_filesystem"),
    "hugepages": ("pages", "proc_meminfo"),
    "swap": ("bytes", None),
    "temperature": ("degrees_celsius", None),
    "smart": (None, None),
    "io_latency": ("seconds", None),
    "containers": (None, None),
}


def _number(value):
    return isinstance(value, (int, float)) and not isinstance(value, bool) and math.isfinite(value)


def _valid_value(name, value):
    if name == "cpu":
        return _number(value) and 0 <= value <= 100
    if name == "load":
        return (
            isinstance(value, list)
            and len(value) == 3
            and all(_number(v) and v >= 0 for v in value)
        )
    if not isinstance(value, dict):
        return False
    remainder = "available" if name == "memory" else "free" if name == "hugepages" else None
    keys = ("total", "used", remainder) if remainder else ("total", "used")
    if not all(_number(value.get(k)) and value[k] >= 0 for k in keys):
        return False
    return (
        value["used"] <= value["total"]
        and (name == "hugepages" or value["total"] > 0)
        and (remainder is None or value["used"] + value[remainder] == value["total"])
    )


def _resource(name, sample, now):
    unit, source = _RESOURCES[name]
    sample = sample if isinstance(sample, dict) else {}
    sampled_at = sample.get("sampled_at")
    age = now - sampled_at if _number(sampled_at) and sampled_at > 0 else None
    value = sample.get("value")
    reason = sample.get("reason")
    if source is None:
        reason = "unsupported"
    elif age is None:
        reason = "missing"
    elif age < 0:
        reason = "clock_changed"
    elif age > _MAX_AGE:
        reason = "stale"
    elif not _valid_value(name, value):
        reason = reason or "invalid_sample"
    return {
        "state": "unavailable" if reason else "available",
        "reason": reason,
        "sampled_at": sampled_at if age is not None else None,
        "age_seconds": age if age is not None and age >= 0 else None,
        "value": None if reason else value,
        "unit": unit,
        "source": source,
    }


def capacity_outlook(rows, filesystem, now):
    segment = []
    reason = "insufficient_history"
    for row in rows[-_MAX_ROWS:]:
        ts, used, total = (row.get(k) for k in ("ts", "disk_used_gb", "disk_total_gb"))
        if not all(_number(v) for v in (ts, used, total)) or total <= 0 or not 0 <= used <= total:
            segment = []
            continue
        if ts > now:
            segment = []
            reason = "clock_changed"
            break
        if ts < now - _WINDOW:
            continue
        if segment:
            previous = segment[-1]
            elapsed = ts - previous["ts"]
            if (
                not 0 < elapsed <= _MAX_GAP
                or total != previous["disk_total_gb"]
                or used < previous["disk_used_gb"]
            ):
                segment = []
        segment.append(row)
    result = {
        "state": "insufficient_history",
        "reason": reason,
        "window_seconds": _WINDOW,
        "sample_count": len(segment),
        "minimum_samples": _MIN_SAMPLES,
        "from": segment[0]["ts"] if segment else None,
        "to": segment[-1]["ts"] if segment else None,
        "growth_bytes_per_day": None,
        "days_remaining": None,
    }
    if filesystem["state"] != "available":
        return {**result, "state": "unavailable", "reason": "filesystem_unavailable"}
    disk = filesystem["value"]
    if not segment or disk["total"] / _GIB != segment[-1]["disk_total_gb"]:
        return {**result, "reason": "capacity_changed" if segment else reason}
    if disk["used"] / _GIB < segment[-1]["disk_used_gb"]:
        return {**result, "reason": "usage_reset"}
    span = segment[-1]["ts"] - segment[0]["ts"]
    if len(segment) < _MIN_SAMPLES or span < (_MIN_SAMPLES - 1) * 3600:
        return result
    if now - segment[-1]["ts"] > _MAX_GAP:
        return {**result, "reason": "stale_history"}
    growth = (segment[-1]["disk_used_gb"] - segment[0]["disk_used_gb"]) * _GIB * 86400 / span
    if growth <= 0:
        return {**result, "state": "no_growth", "reason": "no_measured_growth"}
    return {
        **result,
        "state": "estimated",
        "reason": None,
        "growth_bytes_per_day": growth,
        "days_remaining": (disk["total"] - disk["used"]) / growth,
    }


def build_host_resources(samples, disk_rows, now=None):
    now = time.time() if now is None else now
    samples = samples if isinstance(samples, dict) else {}
    resources = {name: _resource(name, samples.get(name, {}), now) for name in _RESOURCES}
    return {
        **resources,
        "capacity_outlook": capacity_outlook(disk_rows, resources["filesystem"], now),
    }
