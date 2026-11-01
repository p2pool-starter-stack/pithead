from mining_dashboard.helper.utils import effective_hashrate


def reported_level(summary):
    level = summary.get("donate_level") if isinstance(summary, dict) else None
    if isinstance(level, bool) or not isinstance(level, int) or not 0 <= level <= 100:
        return None
    return level


def fleet_donation(workers):
    rigs = [w for w in workers if w.get("status") == "online"]
    hashing = [(effective_hashrate(w), w.get("donate_level")) for w in rigs]
    hashing = [(rate, level) for rate, level in hashing if rate > 0]
    total = sum(rate for rate, _ in hashing)
    known = all(w.get("donate_level") is not None for w in rigs)
    out = {
        "available": bool(hashing) and known,
        "rigs": len(rigs),
        "donating": sum(1 for w in rigs if (w.get("donate_level") or 0) > 0),
        "unknown": sum(1 for w in rigs if w.get("donate_level") is None),
    }
    if out["available"]:
        out["percent"] = round(sum(rate * level for rate, level in hashing) / total, 3)
    return out
