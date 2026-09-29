from mining_dashboard.service.health.monero_health import (
    PEERLESS_SEC,
    STALLED_SEC,
    MoneroChainHealth,
)


class _Clock:
    def __init__(self):
        self.t = 1000.0

    def __call__(self):
        return self.t


def _sync(height=100, out=8, inn=2, **kw):
    return {"reachable": True, "height": height, "peers_out": out, "peers_in": inn, **kw}


def _mon():
    clock = _Clock()
    return MoneroChainHealth(clock=clock), clock


def test_at_tip_with_peers_is_green_with_the_numbers():
    mon, _ = _mon()
    v = mon.observe(_sync())
    assert v["level"] == "green"
    assert (v["peers_out"], v["peers_in"], v["height"]) == (8, 2, 100)
    assert v["reasons"] == [] and v["advice"] == ""


def test_zero_out_peers_is_red_only_once_sustained():
    mon, clock = _mon()
    assert mon.observe(_sync(out=0))["level"] == "green"  # first zero reading starts the clock
    clock.t += PEERLESS_SEC - 1
    assert mon.observe(_sync(height=101, out=0))["level"] == "green"
    clock.t += 1
    v = mon.observe(_sync(height=102, out=0))
    assert v["level"] == "red" and v["peerless"] and not v["stalled"]
    assert v["reasons"] == [f"0 outgoing peers for {PEERLESS_SEC // 60} min"]
    assert "restart monerod" in v["advice"]


def test_one_peer_clears_peerless_and_restarts_the_clock():
    mon, clock = _mon()
    mon.observe(_sync(out=0))
    clock.t += PEERLESS_SEC
    assert mon.observe(_sync(out=0))["level"] == "red"
    assert mon.observe(_sync(out=1))["level"] == "green"
    clock.t += PEERLESS_SEC - 1
    assert mon.observe(_sync(out=0))["level"] == "green"  # a fresh zero, not the old one


def test_a_height_that_stops_moving_is_red_with_the_age():
    mon, clock = _mon()
    mon.observe(_sync(height=100))
    clock.t += STALLED_SEC - 1
    assert mon.observe(_sync(height=100))["level"] == "green"
    clock.t += 1
    v = mon.observe(_sync(height=100))
    assert v["level"] == "red" and v["stalled"] and not v["peerless"]
    assert v["reasons"] == [f"height 100 has not moved for {STALLED_SEC // 60} min"]
    assert v["advance_age_sec"] == STALLED_SEC


def test_normal_block_intervals_do_not_alarm():
    mon, clock = _mon()
    for h in range(100, 140):  # a block every 5 minutes, far slower than Monero's 2
        clock.t += 300
        assert mon.observe(_sync(height=h))["level"] == "green"


def test_a_falling_height_is_not_progress():
    mon, clock = _mon()
    mon.observe(_sync(height=100))
    clock.t += STALLED_SEC
    assert mon.observe(_sync(height=90))["level"] == "red"  # rewound below the best one seen


def test_unreachable_node_is_no_verdict_never_green_and_clears_the_clocks():
    mon, clock = _mon()
    mon.observe(_sync(out=0))
    clock.t += PEERLESS_SEC
    v = mon.observe({"reachable": False})  # node-down is another monitor's verdict
    assert v["level"] == "unknown" and v["reachable"] is False and v["peers_visible"] is False
    clock.t += 1
    assert mon.observe(_sync(out=0))["level"] == "green"  # the peerless clock starts afresh


def test_downtime_is_not_a_stall_and_a_restart_at_the_same_height_restarts_the_clock():
    mon, clock = _mon()
    mon.observe(_sync(height=100))
    clock.t += STALLED_SEC * 2
    assert mon.observe({"reachable": False})["level"] == "unknown"
    v = mon.observe(_sync(height=100))  # back at the same height after a long stop
    assert v["level"] == "green" and v["advance_age_sec"] == 0
    clock.t += STALLED_SEC
    assert mon.observe(_sync(height=100))["level"] == "red"


def test_remote_node_gets_no_verdict_and_says_peers_are_not_visible():
    mon, clock = _mon()
    v = mon.observe(_sync(out=0), local=False)
    assert v["level"] == "unknown" and v["peers_visible"] is False
    clock.t += PEERLESS_SEC + STALLED_SEC
    assert mon.observe(_sync(out=0), local=False)["level"] == "unknown"


def test_a_payload_without_counts_is_no_verdict_and_forgets_old_clocks():
    mon, clock = _mon()
    mon.observe(_sync(out=0))
    clock.t += PEERLESS_SEC
    v = mon.observe({"reachable": True, "is_syncing": False})  # log-scrape / older monerod
    assert v["level"] == "unknown"
    assert mon.observe(_sync(out=0))["level"] == "green"  # the earlier zero was not carried over


# --- unavailable peer readings (#2921) ---------------------------------------------------------
def test_unavailable_peers_are_not_green_and_not_zero():
    mon, _ = _mon()
    v = mon.observe(_sync(out=None, inn=None))
    assert v["level"] == "unknown" and v["peers_visible"] is False
    assert v["peers_out"] is None and v["reasons"] == []


def test_a_reading_gap_does_not_count_as_time_without_peers():
    mon, clock = _mon()
    mon.observe(_sync(out=0))
    clock.t += PEERLESS_SEC - 1
    assert mon.observe(_sync(height=101, out=None))["level"] == "unknown"
    clock.t += 5  # past the bound since the first zero, but the clock restarted in the gap
    v = mon.observe(_sync(height=102, out=0))
    assert v["level"] == "green" and not v["peerless"]


def test_a_stalled_height_is_still_red_when_peers_are_unavailable():
    mon, clock = _mon()
    mon.observe(_sync(out=None, inn=None))
    clock.t += STALLED_SEC
    v = mon.observe(_sync(out=None, inn=None))
    assert v["level"] == "red" and v["stalled"] and v["peers_visible"] is False
