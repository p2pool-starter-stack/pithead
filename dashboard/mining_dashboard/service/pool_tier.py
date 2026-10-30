import math
import time

from mining_dashboard.config.defaults import TABLE

POOL_TIER_HPS = TABLE["runtime"]["pool_tier_hps"]


def suggest_pool_tier(history: list[dict], current: str, *, now: float | None = None):
    now = time.time() if now is None else now
    cutoff = now - 86400
    samples = [
        (row.get("timestamp", 0), row.get("v", 0))
        for row in history
        if isinstance(row.get("timestamp"), (int, float))
        and isinstance(row.get("v"), (int, float))
        and math.isfinite(row["timestamp"])
        and math.isfinite(row["v"])
        and row["v"] >= 0
        and row["timestamp"] <= now
    ]
    if not samples or min(t for t, _ in samples) > cutoff:
        return None
    recent = [value for timestamp, value in samples if timestamp >= cutoff]
    if not recent or max(t for t, _ in samples) < now - 300:
        return None
    average = sum(recent) / len(recent)
    tier = (
        "nano"
        if average < POOL_TIER_HPS["mini"]
        else "mini"
        if average < POOL_TIER_HPS["main"]
        else "main"
    )
    if current.lower() not in ("nano", "mini", "main") or tier == current.lower():
        return None
    return {"tier": tier, "hashrate_24h": average, "provisional": True}
