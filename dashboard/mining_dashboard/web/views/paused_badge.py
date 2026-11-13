from mining_dashboard.config.config import monero_is_local
from mining_dashboard.service.mining_verdict import BACKUP


def _paused_reason(data, metrics):
    if data.get("stratum_closed"):
        return "stratum closed"
    health = (data.get("monero_sync") or {}).get("health") or {}
    if monero_is_local() and not metrics.monero.down and health.get("level") == "red":
        return "node out of sync"
    if metrics.global_syncing:
        return "node syncing"
    p2p = (data.get("pool") or {}).get("p2p") or {}
    if p2p.get("uptime", 0) > 0 and not p2p.get("out_peers", 0) and not p2p.get("in_peers", 0):
        return "P2Pool isolated"
    return None


def paused_badges(data, metrics):
    reason = _paused_reason(data, metrics)
    if not reason:
        return []
    workers = data.get("workers") or []
    moved = sum(1 for w in workers if (w.get("mining") or {}).get("state") == BACKUP)
    text = f"Mining paused here: {reason}"
    if moved:
        text += f", {moved} rig{'' if moved == 1 else 's'} on backup pool"
    return [{"text": text, "variant": "bad"}]
