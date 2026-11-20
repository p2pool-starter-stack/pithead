import time


def snapshot_line(snap, now=None):
    if not isinstance(snap, dict):
        return ""
    now = time.time() if now is None else now
    boot = snap.get("bootstrap") or {}
    cons = snap.get("consensus") or {}
    guards = snap.get("guards") or {}
    circuits = snap.get("circuits") or []
    taken = snap.get("taken_at")
    age = cons.get("age_sec")
    parts = [
        f"control {'ok' if snap.get('control') == 'ok' else 'unreachable'}",
        f"version {snap.get('version') or 'unknown'}",
        f"bootstrap {boot.get('progress') if boot.get('progress') is not None else '?'}%"
        + (f" ({boot['tag']})" if boot.get("tag") else ""),
        "consensus age "
        + (f"{int(age) // 60} min" if isinstance(age, (int, float)) else "unknown")
        + f" ({cons.get('source') or 'none'})",
        "guards " + (", ".join(f"{k} {v}" for k, v in sorted(guards.items())) or "none"),
        "circuits "
        + (
            ", ".join(f"{c.get('state')} {c.get('purpose')} {c.get('count')}" for c in circuits)
            or "none"
        ),
    ]
    when = f" taken {int(now - taken) // 60} min ago" if isinstance(taken, (int, float)) else ""
    return f"Tor snapshot{when}: " + "; ".join(parts) + "."
