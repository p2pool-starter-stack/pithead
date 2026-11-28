import bisect
import time

import mining_dashboard.web.views.charts as charts
import mining_dashboard.web.views.series_views as series_views
from mining_dashboard.config.config import DEFAULT_HASHRATE_WINDOW


def old_filter_range(history, shares, range_arg, window=None):
    if window is not None:
        lo, hi = window
        return (
            [x for x in history if lo <= x["timestamp"] <= hi],
            [s for s in shares if lo <= s["ts"] <= hi],
        )
    if range_arg == "all":
        return history, shares
    target_seconds = charts._RANGE_SECONDS.get(range_arg, 0)
    if target_seconds <= 0:
        return history, shares
    cutoff = time.time() - target_seconds
    return (
        [x for x in history if x["timestamp"] >= cutoff],
        [s for s in shares if s["ts"] >= cutoff],
    )


def old_downsample_history(filtered_history, duration_s):
    target = charts._target_points(duration_s)
    if target <= 0 or len(filtered_history) <= target:
        return filtered_history

    chunk_size = len(filtered_history) / target
    downsampled = []
    for i in range(target):
        chunk = filtered_history[int(i * chunk_size) : int((i + 1) * chunk_size)]
        if not chunk:
            continue
        mid = chunk[len(chunk) // 2]
        row = {"t": mid["t"], "timestamp": mid["timestamp"]}
        for col in charts._DOWNSAMPLE_VALUE_COLUMNS:
            row[col] = round(sum(x.get(col, 0) or 0 for x in chunk) / len(chunk), 2)
        downsampled.append(row)
    return downsampled


def old_share_points(filtered_history, filtered_shares):
    if not (filtered_history and filtered_shares):
        return []

    hist_ts = [x["timestamp"] for x in filtered_history]
    counts = {}
    for s in filtered_shares:
        s_ts = s["ts"]
        idx = bisect.bisect_left(hist_ts, s_ts)
        candidates = []
        if idx < len(hist_ts):
            candidates.append(idx)
        if idx > 0:
            candidates.append(idx - 1)
        if candidates:
            closest_idx = min(candidates, key=lambda i: abs(hist_ts[i] - s_ts))
            counts[closest_idx] = counts.get(closest_idx, 0) + 1

    points = []
    for idx in sorted(counts):
        count = counts[idx]
        points.append(
            {
                "x": int(hist_ts[idx] * 1000),
                "y": charts._SHARE_MARKER_Y,
                "r": min(6 + (count * 3), 15),
                "c": count,
            }
        )
    return points


def old_build_chart(
    history,
    shares,
    range_arg,
    window=None,
    avg_window=DEFAULT_HASHRATE_WINDOW,
    events=None,
    raffle_wins=None,
    payouts=None,
):
    filtered_history, filtered_shares = old_filter_range(history, shares, range_arg, window)
    duration_s = charts._window_duration(filtered_history, range_arg, window)
    filtered_history = old_downsample_history(filtered_history, duration_s)

    timestamps = [x["timestamp"] for x in filtered_history]
    gap_after = charts._gap_after_indices(timestamps)

    p2pool = []
    xvb = []
    for i, x in enumerate(filtered_history):
        vp, vx = charts._split_values(x, avg_window)
        x_ms = int(timestamps[i] * 1000)
        p2pool.append({"x": x_ms, "y": vp})
        xvb.append({"x": x_ms, "y": vx})
        if i in gap_after:
            mid_ms = int(((timestamps[i] + timestamps[i + 1]) / 2) * 1000)
            p2pool.append({"x": mid_ms, "y": None})
            xvb.append({"x": mid_ms, "y": None})

    return {
        "p2pool": p2pool,
        "xvb": xvb,
        "shares": old_share_points(filtered_history, filtered_shares),
        "events": charts._event_points(charts._filter_events(events or [], range_arg, window)),
        "raffle": charts._raffle_points(
            charts._filter_events(raffle_wins or [], range_arg, window)
        ),
        "payouts": charts._payout_points(charts._filter_events(payouts or [], range_arg, window)),
        "tension": charts._chart_tension(duration_s),
    }


def old_avg_p2pool_over_window(history, window_seconds):
    if not history:
        return 0.0

    cutoff = time.time() - window_seconds
    total = 0.0
    count = 0
    for x in history:
        if x.get("timestamp", 0) < cutoff:
            continue
        vp = x.get("v_p2pool", 0) or 0
        vx = x.get("v_xvb", 0) or 0
        v = x.get("v", 0) or 0
        if vp == 0 and vx == 0 and v > 0:
            vp = v
        total += vp
        count += 1

    return total / count if count else 0.0


def old_avg_xvb_over_window(history, window_seconds):
    if not history:
        return 0.0

    cutoff = time.time() - window_seconds
    total = 0.0
    count = 0
    for x in history:
        if x.get("timestamp", 0) < cutoff:
            continue
        total += x.get("v_xvb", 0) or 0
        count += 1

    return total / count if count else 0.0


def old_share_reject_pct(rows, window_sec, now=None):
    cutoff = (now if now is not None else time.time()) - window_sec
    accepted = rejected = 0
    for r in rows:
        if r["ts"] >= cutoff:
            accepted += r.get("accepted", 0) or 0
            rejected += r.get("rejected", 0) or 0
    total = accepted + rejected
    return (rejected / total * 100) if total > 0 else None


def old_shares_in_pplns_window(shares, pplns_window, block_time, now=None):
    if now is None:
        now = time.time()
    cutoff = now - pplns_window * block_time
    return sum(1 for s in shares if s.get("ts", 0) >= cutoff)


def old_pplns_weight_in_window(shares, pplns_window, block_time, now=None):
    if now is None:
        now = time.time()
    cutoff = now - pplns_window * block_time
    return sum(s.get("difficulty", 0) or 0 for s in shares if s.get("ts", 0) >= cutoff)


def old_filter_share_stats(rows, range_arg, window=None):
    if window is not None:
        lo, hi = window
        return [s for s in rows if lo <= s["ts"] <= hi]
    if range_arg == "all":
        return rows
    secs = series_views._RANGE_SECONDS.get(range_arg, 0)
    if secs <= 0:
        return rows
    cutoff = time.time() - secs
    return [s for s in rows if s["ts"] >= cutoff]


def old_downsample_share_stats(rows, target=series_views._MAX_CHART_POINTS):
    if len(rows) <= target:
        return rows
    chunk_size = len(rows) / target
    out = []
    for i in range(target):
        chunk = rows[int(i * chunk_size) : int((i + 1) * chunk_size)]
        if not chunk:
            continue
        bucket = {"ts": chunk[len(chunk) // 2]["ts"]}
        for col in ("accepted", "rejected", "invalid", "expired"):
            bucket[col] = sum(r.get(col, 0) or 0 for r in chunk)
        out.append(bucket)
    return out


def old_downsample_gauge_rows(rows, value_cols, target=series_views._MAX_CHART_POINTS):
    if len(rows) <= target:
        return rows
    chunk_size = len(rows) / target
    out = []
    for i in range(target):
        chunk = rows[int(i * chunk_size) : int((i + 1) * chunk_size)]
        if not chunk:
            continue
        bucket = {"ts": chunk[len(chunk) // 2]["ts"]}
        for col in value_cols:
            vals = [r.get(col, 0) or 0 for r in chunk]
            bucket[col] = round(sum(vals) / len(vals), 2)
        out.append(bucket)
    return out
