import math

from mining_dashboard.config.config import (
    XVB_MIN_TIME_SEND_MS,
    XVB_SWITCH_OVERHEAD_MS,
    XVB_TIME_ALGO_MS,
)


def plan_cycle(
    xvb_ms,
    debt_ms,
    percent,
    max_fraction,
    *,
    cycle_ms=XVB_TIME_ALGO_MS,
    min_slice_ms=60_000,
    min_dwell_ms=XVB_MIN_TIME_SEND_MS,
    overhead_ms=XVB_SWITCH_OVERHEAD_MS,
):
    for name, value, minimum in (
        ("xvb_ms", xvb_ms, 0),
        ("cycle_ms", cycle_ms, 1),
        ("min_slice_ms", min_slice_ms, 1),
        ("min_dwell_ms", min_dwell_ms, 1),
        ("overhead_ms", overhead_ms, 0),
    ):
        if not isinstance(value, int) or value < minimum:
            raise ValueError(f"{name} must be an integer >= {minimum}")
    for name, value, minimum, maximum in (
        ("debt_ms", debt_ms, 0, math.inf),
        ("percent", percent, 0.1, 10),
        ("max_fraction", max_fraction, 0, 1),
    ):
        if not math.isfinite(value) or not minimum <= value <= maximum:
            raise ValueError(f"{name} must be finite and between {minimum} and {maximum}")

    min_p2pool_ms = max(30_000, min_dwell_ms)
    if cycle_ms < min_p2pool_ms:
        raise ValueError("cycle_ms must accommodate the P2Pool minimum remainder")
    if xvb_ms not in (0, cycle_ms) and not min_dwell_ms <= xvb_ms <= cycle_ms - min_p2pool_ms:
        raise ValueError(
            "xvb_ms must be zero, a full cycle, or leave minimum XvB dwell and P2Pool remainder"
        )

    accrued_ms = debt_ms + percent / 100 * cycle_ms
    project_ms = 0
    if accrued_ms >= min_slice_ms:
        capacity_ms = max(
            0, min(cycle_ms * max_fraction - xvb_ms, cycle_ms - xvb_ms - min_p2pool_ms)
        )
        candidate_ms = math.floor(min(accrued_ms, capacity_ms))
        if candidate_ms >= min_dwell_ms:
            project_ms = candidate_ms

    segments = [
        (name, duration)
        for name, duration in (
            ("xvb", xvb_ms),
            ("p2pool", cycle_ms - xvb_ms - project_ms),
            ("project", project_ms),
        )
        if duration > 0
    ]
    return segments, min(3 * cycle_ms, accrued_ms - project_ms)
