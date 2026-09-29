"""The XMR Network card's node block (#2499, and #32's DB size): what monerod is, how big its DB is,
and whether it is at the tip with peers."""

from mining_dashboard.helper.utils import format_duration

HEALTH_TIP = (
    "Green means monerod is at the network tip with peers: it has outgoing peers and its height "
    "has moved in the last 30 minutes (Monero blocks arrive about every 2). Red means it has had "
    "no outgoing peers for 10 minutes or its height has not moved for 30 minutes, with the numbers "
    "shown. A remote node's peers are not visible to this stack, so no verdict is given."
)


def _db_size(monero_sync):
    """Human-readable on-disk Monero DB size (Issue #32); em-dash when unknown."""
    db_bytes = monero_sync.get("db_size", 0) or 0
    return f"{db_bytes / 1e9:.1f} GB" if db_bytes > 0 else "—"


def _health(health):
    """Display fields for the node verdict; ``level`` is green/red/unknown."""
    health = health or {}
    level = health.get("level", "unknown")
    if level == "unknown":
        why = (
            "Node not answering — see its down status"
            if health.get("reachable") is False
            else "Peers not visible right now — no health verdict"
        )
        return {
            "level": "unknown",
            "status": why,
            "peers": "—",
            "moved": "—",
            "reasons": [],
            "advice": "",
            "tooltip": HEALTH_TIP,
        }
    out, inn = health.get("peers_out"), health.get("peers_in")
    age = health.get("advance_age_sec")
    reasons = health.get("reasons") or []
    return {
        "level": level,
        "status": "; ".join(reasons) if reasons else "At tip, with peers",
        "peers": "—" if out is None else f"{out} out / {inn if inn is not None else '—'} in",
        "moved": "—" if age is None else f"{format_duration(age)} ago",
        "reasons": reasons,
        "advice": health.get("advice", ""),
        "tooltip": HEALTH_TIP,
    }


def build_monero(data, metrics):
    monero_sync = data.get("monero_sync", {})
    return {
        "mode": metrics.monero_mode,
        "db_size": _db_size(monero_sync),
        "health": _health(monero_sync.get("health")),
    }
