import math
import random
import time

from mining_dashboard.config.config import HASHRATE_WINDOW_COLUMNS

CASES = 2500
HISTORY_COLUMNS = ("v",) + tuple(col for cols in HASHRATE_WINDOW_COLUMNS.values() for col in cols)
HISTORY_COLUMNS = tuple(dict.fromkeys(HISTORY_COLUMNS))
STAT_COLUMNS = ("accepted", "rejected", "invalid", "expired")
GAUGE_COLUMNS = ("avg_1h", "avg_24h", "fail_count", "donation_fraction")


def make_rng(seed):
    return random.Random(seed)  # noqa: S311


def outcome(fn, *args, **kwargs):
    try:
        return ("ok", repr(fn(*args, **kwargs)))
    except Exception as exc:
        return ("err", type(exc).__name__)


def timestamps(rng, n, mode):
    base = rng.choice([1_000, 1_700_000_000, 1_700_000_000.25])
    step = rng.choice([1, 30, 30.5, 0.001, 1000])
    out = []
    t = base
    for _ in range(n):
        t += rng.choice([0, step, step, step * rng.random(), step * 3])
        out.append(t)
    if mode == "equal":
        out = [out[0] if out else 0] * n
    elif mode == "backstep" and n > 2:
        for _ in range(rng.randint(1, 3)):
            i = rng.randrange(1, n)
            out[i] = out[i] - rng.choice([1, 100, 10 * step, 10_000])
    elif mode == "random":
        out = [rng.choice([base, base + step * rng.randint(0, max(n, 1))]) for _ in range(n)]
    elif mode == "reversed":
        out.reverse()
    return out


def cell(rng, profile, strings=True):
    if profile == "float":
        return rng.choice([0.0, -0.0, round(rng.uniform(0, 9000), 2), rng.uniform(0, 5e3), 1e-9])
    if profile == "int":
        return rng.choice([0, 0, rng.randint(0, 5000)])
    if profile == "mixed":
        return rng.choice([0, 0.0, rng.randint(0, 99), rng.uniform(0, 99), 2**60 + 1, 1e16])
    pool = [None, True, False, 0, 0.0, 7, 2.5]
    if rng.random() < 0.15:
        pool += [math.nan, math.inf, 2**62]
        if strings:
            pool += ["", "x"]
    return rng.choice(pool)


def history_rows(rng, n, mode, strings=True):
    stamps = timestamps(rng, n, mode)
    profile = {
        col: rng.choice(["float", "float", "int", "mixed", "dirty"]) for col in HISTORY_COLUMNS
    }
    if rng.random() < 0.7:
        profile = {col: "float" for col in HISTORY_COLUMNS}
    rows = []
    for i, ts in enumerate(stamps):
        row = {"t": f"t{i}", "timestamp": ts}
        for col in HISTORY_COLUMNS:
            if profile[col] == "dirty" and rng.random() < 0.1:
                continue
            row[col] = cell(rng, profile[col], strings)
        rows.append(row)
    return rows


def share_rows(rng, n, mode):
    return [
        {"ts": ts, "difficulty": cell(rng, rng.choice(["int", "float", "dirty"]))}
        for ts in timestamps(rng, n, mode)
    ]


def stat_rows(rng, n, mode):
    profile = rng.choice(["int", "int", "int", "float", "mixed", "dirty"])
    rows = []
    for ts in timestamps(rng, n, mode):
        row = {"ts": ts}
        for col in STAT_COLUMNS:
            if profile == "dirty" and rng.random() < 0.1:
                continue
            row[col] = cell(rng, profile)
        rows.append(row)
    return rows


def gauge_rows(rng, n, mode):
    rows = []
    profile = {col: rng.choice(["float", "int", "mixed", "dirty"]) for col in GAUGE_COLUMNS}
    for ts in timestamps(rng, n, mode):
        row = {"ts": ts}
        for col in GAUGE_COLUMNS:
            if profile[col] == "dirty" and rng.random() < 0.1:
                continue
            row[col] = cell(rng, profile[col])
        rows.append(row)
    return rows


def sizes(rng):
    return rng.choice([0, 1, 1, 2, 3, 5, 12, 40, 150, 800])


def modes(rng):
    return rng.choice(["ordered", "ordered", "ordered", "equal", "backstep", "random", "reversed"])


def views_of(rows, field, order):
    return order.view(field, field, rows)


def pick_bounds(rng, rows, field):
    values = [r[field] for r in rows if isinstance(r.get(field), int | float)]
    values = [v for v in values if v == v and abs(v) != math.inf]
    anchors = values + [0, 1e12, -5]
    lo = rng.choice(anchors) + rng.choice([0, 0, -1, 1, 0.5])
    hi = rng.choice(anchors) + rng.choice([0, 0, -1, 1, 0.5])
    return lo, hi


def pick_now(rng, rows, field):
    values = [
        r[field] for r in rows if isinstance(r.get(field), int | float) and r[field] == r[field]
    ]
    return (max(values) if values else 1_700_000_000) + rng.choice(
        [0, 0, 5, 4000, 90_000, 5_000_000]
    )


def pin_clock(monkeypatch):
    clock = {"now": 1_700_000_000.0}
    monkeypatch.setattr(time, "time", lambda: clock["now"])
    return clock


SUM_CELLS = [
    [0.0, 0.0, 0.0],
    [-0.0, -0.0],
    [0, 0, 0],
    [0, 0.0, 2],
    [0.0, 0.0, 2],
    [1.5, 0.0, 2.25],
    [True, False, 3],
    [None, 1.5, 2.5],
    [0.1, 0.2, 0.3, 0.4, 0.5, 0.6, 0.7],
    [2**60 + 1, 1, 0.0],
    [2**53 + 1, 1.0, 2**53 + 3],
    [1e308, 1e308, -1e308],
    [math.nan, 1.0],
    [math.inf, 0.0],
    [3, 4.5, 0],
    [1, 2, 3],
]
