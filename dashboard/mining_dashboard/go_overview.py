import os
import time
from dataclasses import asdict, is_dataclass

from mining_dashboard.web.views import views, xvb_views


def json_value(value):
    if is_dataclass(value) and not isinstance(value, type):
        return json_value(asdict(value))
    if isinstance(value, dict):
        return {key: json_value(item) for key, item in value.items()}
    if isinstance(value, (list, tuple)):
        return [json_value(item) for item in value]
    if hasattr(value, "__dict__"):
        return json_value(vars(value))
    return value


def badge_settings():
    monero_local = xvb_views.monero_is_local()
    tari_local = xvb_views.tari_is_local()
    return {
        "disk_warn_percent": xvb_views.DISK_WARN_PERCENT,
        "disk_critical_percent": xvb_views.DISK_CRITICAL_PERCENT,
        "low_ram_available_gb": xvb_views.LOW_RAM_AVAILABLE_GB,
        "low_ram_floor_gb": xvb_views.low_ram_floor_gb(monero_local, tari_local),
        "monero_local": monero_local,
        "tari_local": tari_local,
    }


def request(operation, args):
    return {
        "operation": operation,
        "args": json_value(args),
        "now": time.time(),
        "zone": os.environ.get("TZ", ""),
    }


def builders(captured):
    def pool(data, metrics, monero_builder=None):
        monero = (views.build_monero if monero_builder is None else monero_builder)(data, metrics)
        captured["pool_network"] = request("build_pool_network", [data, metrics, monero])
        return {**dict.fromkeys(("stratum", "pool", "network", "shares_window")), "monero": monero}

    def badges(data, metrics, mode_variant, db_healthy=True, wallet_change=None):
        captured["badges"] = request(
            "build_badges",
            [data, metrics, mode_variant, db_healthy, wallet_change, badge_settings()],
        )
        return []

    result = {"build_pool_network": pool, "build_badges": badges}
    for operation, field in (
        ("build_raffle_log", "raffle_wins"),
        ("build_raffle_eligibility", "raffle_eligible"),
        ("_egress_badge", "egress_badge"),
        ("visible_update", "update"),
    ):

        def capture(*args, operation=operation, field=field):
            if operation == "visible_update":
                running = (views.resolve_version() or {}).get("text") if args[0] else None
                args = (*args, running)
            captured[field] = request(operation, args)

        result[operation] = capture
    return result
