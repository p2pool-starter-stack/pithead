import logging

logger = logging.getLogger("AlertLevels")

CRITICAL_EVENTS = frozenset(
    {
        "node_down",
        "node_recovered",
        "container_unhealthy",
        "db_unhealthy",
        "disk_space",
        "hashrate_loss",
    }
)
IMPORTANT_EVENTS = CRITICAL_EVENTS | frozenset(
    {
        "worker_offline",
        "worker_recovered",
        "sync_finished",
        "db_reset",
        "xvb_no_share",
        "xvb_registration",
        "hashrate_low",
        "high_reject_rate",
        "hugepages",
        "low_ram",
        "payout_found",
        "payout_confirmed",
        "raffle_win",
    }
)
ALL_EVENTS = IMPORTANT_EVENTS | frozenset(
    {"worker_joined", "worker_left", "stack_online", "daily_summary", "block_found", "new_release"}
)
ALWAYS_ON_EVENTS = frozenset({"wallet_changed", "clearnet_exposed", "payout_wallet_down"})

LEVEL_EVENTS = {
    "off": frozenset(),
    "critical": CRITICAL_EVENTS,
    "important": IMPORTANT_EVENTS,
    "all": ALL_EVENTS,
}


def normalize_level(value):
    level = str(value or "").strip().lower()
    if not level:
        return "off"
    if level not in LEVEL_EVENTS:
        logger.warning("Unknown telegram.level %r — using 'all'.", level)
        return "all"
    return level


def level_delivers(level, event):
    return event in ALWAYS_ON_EVENTS or event in LEVEL_EVENTS[normalize_level(level)]
