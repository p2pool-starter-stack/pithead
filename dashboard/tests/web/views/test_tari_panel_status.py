"""build_tari's status text for a node off the chain (#2464): the panel prints this string as-is."""

from mining_dashboard.web.views.infra_views import build_tari

READY = {"active": True, "connected": True, "status": "READY"}


def _health(level, merge="on"):
    return {
        "level": level,
        "reasons": ["tip 1 unchanged for 30 min", "0 peer connections for 28 min"],
        "advice": "restart the Tari node",
        "merge_mining": merge,
    }


def test_red_replaces_the_ready_channel_with_reasons_advice_and_the_mining_state():
    t = build_tari({"tari": READY, "tari_sync": {"health": _health("red", "suppressed")}})
    assert t["status"] == (
        "Not following the chain: tip 1 unchanged for 30 min; 0 peer connections for 28 min. "
        "restart the Tari node Tari merge-mining is paused until it recovers; Monero mining continues."
    )
    assert t["health"]["level"] == "red"


def test_green_or_missing_verdict_keeps_the_channel_status():
    assert (
        build_tari({"tari": READY, "tari_sync": {"health": _health("green")}})["status"] == "READY"
    )
    assert build_tari({"tari": READY})["status"] == "READY"
