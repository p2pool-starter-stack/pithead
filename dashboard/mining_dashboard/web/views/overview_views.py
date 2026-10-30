import math
import time

from mining_dashboard.config import config
from mining_dashboard.helper.utils import format_hashrate


def reading(value):
    return value if type(value) in (int, float) and math.isfinite(value) and value >= 0 else None


def timestamp(value):
    return (
        value
        if reading(value) is not None and 0 < value <= min(time.time(), 8_640_000_000_000)
        else None
    )


def build_overview(data, metrics, payouts, history):
    stratum = data.get("stratum") or {}
    system = data.get("system") or {}
    tor = data.get("tor_health") or {}
    tor_health = None
    if (
        tor.get("running") is False
        or tor.get("restarting") is True
        or tor.get("health") == "unhealthy"
    ):
        tor_health = "unhealthy"
    elif tor.get("running") is True and tor.get("health") == "healthy":
        tor_health = "healthy"
    valid_payouts = [
        payout
        for payout in payouts or []
        if timestamp(payout.get("ts")) is not None
        and reading(payout.get("amount_atomic")) is not None
    ]
    latest = max(valid_payouts, key=lambda payout: payout["ts"], default=None)
    live_rate = reading(data.get("total_live_h15"))
    times = [row["timestamp"] for row in history if timestamp(row.get("timestamp")) is not None]
    bounds = {"from": min(times), "to": max(times)} if len(set(times)) > 1 else None
    recent_history = any(
        timestamp(row.get("timestamp")) is not None
        and row["timestamp"] >= time.time() - 86400
        and (
            reading(row.get("v")) is not None
            or (reading(row.get("v_p2pool")) is not None and reading(row.get("v_xvb")) is not None)
        )
        for row in history
    )
    return {
        "history_window": bounds,
        "hashrate_now": format_hashrate(live_rate) if live_rate is not None else None,
        "hashrate_24h": format_hashrate(metrics.p2pool_24h + metrics.xvb_routed_24h)
        if recent_history
        else None,
        "last_payout": {"ts": latest["ts"], "amount": latest["amount_atomic"]} if latest else None,
        "snapshot_ts": reading(data.get("timestamp")),
        "shares_found": reading(stratum.get("shares_found")),
        "shares_failed": reading(stratum.get("shares_failed")),
        "effort": reading(stratum.get("current_effort")),
        "tor_health": tor_health,
        "tari_enabled": config.TARI_MODE != "off",
        "xvb_enabled": config.ENABLE_XVB,
        "system_available": bool(system),
        "system_fields": [key for key in ("cpu_percent", "memory", "disk") if key in system],
        "hugepages_available": "hugepages" in system,
    }


def build_mining_activity(shares, events, blocks, payouts, raffle_wins):
    entries = []
    for rows, text in (
        (shares, "P2Pool share recorded; a share does not promise a payout"),
        (events, "Mining status changed"),
        (blocks, "P2Pool block found"),
        (payouts or [], "Confirmed Monero payout"),
        (raffle_wins, "XvB raffle win recorded"),
    ):
        for row in rows:
            ts = timestamp(row.get("ts"))
            if ts is not None and ts > 0:
                entries.append({"ts": ts, "source": "Mining", "text": text})
    entries.sort(key=lambda entry: (-entry["ts"], entry["text"]))
    return {"entries": entries[:1000], "truncated": len(entries) > 1000}
