"""RigForge worker telemetry presentation."""

from mining_dashboard.client.rigforge_freshness import feed_age, feed_stale
from mining_dashboard.helper.utils import format_duration


def _num(value):
    return value if isinstance(value, (int, float)) and not isinstance(value, bool) else None


def _fmt(value):
    return str(int(value)) if isinstance(value, float) and value.is_integer() else str(value)


def rigforge_display(rf, proxy_online=False):
    """Build worker-list chips and Worker Inspect rows from a current agent report."""
    if not rf:
        return None
    if feed_stale(rf):
        age = feed_age(rf.get("generated_at"))
        if age is None and "generated_at" not in rf:
            age = rf.get("age_sec")
        value = f"stale for {format_duration(age)}" if age is not None else "freshness unknown"
        title = (
            f"RigForge's report is {format_duration(age)} old. Live agent version, miner state, "
            "temperature and health are hidden until a current report arrives."
            if age is not None
            else "This RigForge report has no valid generation stamp, so its live agent version, "
            "miner state, temperature and health cannot be trusted."
        )
        row = {"label": "Agent report", "value": value, "variant": "warn", "title": title}
        return {
            "version": None,
            "miner_down": False,
            "chips": [{"text": f"agent {value}", "variant": "warn", "title": title}],
            "stats": [row],
        }
    rows = []

    def add(label, value, chip, variant, title):
        rows.append(
            {"label": label, "value": value, "chip": chip, "variant": variant, "title": title}
        )

    if rf.get("miner_down"):
        add(
            "Miner",
            "agent reports down" if proxy_online else "down",
            "agent reports miner down" if proxy_online else "miner down",
            "warn" if proxy_online else "bad",
            (
                "The current RigForge report cannot reach XMRig, but the proxy still sees this "
                "worker connected and accepting shares. Proxy-observed mining state wins."
                if proxy_online
                else "RigForge is up but its XMRig API is unreachable, and the proxy does not see "
                "the worker online."
            ),
        )

    health = rf.get("health") or {}
    if health.get("throttling") is True:
        add("CPU", "throttling", "throttling", "bad", "CPU is thermal/power throttling.")
    governor = health.get("governor")
    if governor:
        ok = governor == "performance"
        add(
            "Governor",
            governor,
            f"gov: {governor}",
            "ok" if ok else "warn",
            "CPU frequency governor"
            + ("" if ok else " — 'performance' is recommended for mining."),
        )
    hugepages = _num(health.get("hugepages_total"))
    if hugepages is not None:
        add(
            "HugePages",
            _fmt(hugepages),
            f"HP {_fmt(hugepages)}",
            "outline",
            f"HugePages allocated: {_fmt(hugepages)}.",
        )
    board = health.get("board")
    if board:
        add("Mainboard", board, board, "outline", "Mainboard (firmware).")

    power = rf.get("power") or {}
    watts, efficiency = _num(power.get("watts")), _num(power.get("hs_per_watt"))
    if watts is not None or efficiency is not None:
        parts = []
        if watts is not None:
            parts.append(f"{_fmt(round(watts, 1))} W")
        if efficiency is not None:
            parts.append(f"{_fmt(round(efficiency, 1))} H/s·W")
        text = " · ".join(parts)
        add("Power / efficiency", text, text, "outline", "Power draw / efficiency.")

    tune = rf.get("tune") or {}
    if tune.get("target"):
        add(
            "Tuning target",
            tune["target"],
            f"tune: {tune['target']}",
            "outline",
            "Active tuning target.",
        )
    if tune.get("autotune_enabled") and tune.get("autotune_next"):
        add(
            "Autotune",
            tune["autotune_next"],
            f"autotune → {tune['autotune_next']}",
            "outline",
            "Next scheduled autotune run.",
        )

    watchdog = rf.get("watchdog") or {}
    if watchdog.get("enabled"):
        temp, maximum = _num(watchdog.get("temp_c")), _num(watchdog.get("max_temp_c"))
        if watchdog.get("thermal_hold") is True:
            add(
                "Watchdog",
                "thermal hold",
                "thermal hold",
                "bad",
                "Watchdog is holding the rig back — temperature above its ceiling.",
            )
        elif temp is not None:
            text = f"{_fmt(round(temp, 1))}°C"
            if maximum is not None:
                text += f" / {_fmt(maximum)}°C"
            add("Temp / max", text, text, "outline", "Watchdog temperature / ceiling.")

    return {
        "version": rf.get("version"),
        "miner_down": bool(rf.get("miner_down")),
        "chips": [
            {"text": row["chip"], "variant": row["variant"], "title": row["title"]} for row in rows
        ],
        "stats": [
            {
                "label": row["label"],
                "value": row["value"],
                "variant": row["variant"],
                "title": row["title"],
            }
            for row in rows
        ],
    }
