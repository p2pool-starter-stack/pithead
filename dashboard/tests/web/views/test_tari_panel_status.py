"""build_tari's status text for a node off the chain (#2464): the panel prints this string as-is."""

from mining_dashboard.web.views.infra_views import build_tari

READY = {"active": True, "connected": True, "status": "READY"}


def _health(level):
    return {
        "level": level,
        "reasons": ["tip 1 unchanged for 30 min", "0 peer connections for 28 min"],
        "advice": "restart the Tari node",
    }


def test_red_replaces_the_ready_channel_with_its_reasons_and_advice():
    t = build_tari({"tari": READY, "tari_sync": {"health": _health("red")}})
    assert t["status"] == (
        "Not following the chain: tip 1 unchanged for 30 min; 0 peer connections for 28 min. "
        "restart the Tari node"
    )
    assert t["health"]["level"] == "red"


def test_green_or_missing_verdict_keeps_the_channel_status():
    assert (
        build_tari({"tari": READY, "tari_sync": {"health": _health("green")}})["status"] == "READY"
    )
    assert build_tari({"tari": READY})["status"] == "READY"
