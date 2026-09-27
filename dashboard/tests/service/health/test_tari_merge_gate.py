"""TariMergeMineGate (#2464): red stops Tari merge-mining without stopping Monero; recovery resumes it."""

import asyncio
from unittest.mock import AsyncMock

from mining_dashboard.service.health import tari_merge_gate as mg
from mining_dashboard.service.health.tari_merge_gate import TariMergeMineGate

RED = {"level": "red", "reasons": ["tip 1 unchanged for 30 min"]}
GREEN = {"level": "green", "reasons": []}


class Clock:
    t = 1000.0

    def __call__(self):
        return self.t


def _gate(tmp_path, ok=True):
    docker = AsyncMock()
    docker.stop.return_value = docker.start.return_value = ok
    clock = Clock()
    return TariMergeMineGate(str(tmp_path), docker, clock=clock), docker, clock


def _run(gate, clock, verdict, seconds, advanced_at=None, running=True):
    out = None
    for _ in range(int(seconds // 60) + 1):
        out = asyncio.run(gate.apply(verdict, advanced_at, running))
        clock.t += 60
    return out


def test_sustained_red_suspends_merge_mining_and_relaunches_only_p2pool(tmp_path):
    """Covers auto-restart off or exhausted too: the gate reads the verdict, never the restart."""
    gate, docker, clock = _gate(tmp_path)
    assert _run(gate, clock, RED, mg.SUPPRESS_AFTER_SEC - 60) == "on"
    assert _run(gate, clock, RED, 60) == "suppressed"
    assert (tmp_path / mg.MARKER).exists()
    docker.stop.assert_awaited_once()
    assert (
        docker.stop.await_args.args[0] == "p2pool" and docker.start.await_args.args[0] == "p2pool"
    )
    _run(gate, clock, RED, 3600)  # a red that lasts: no further restarts
    assert docker.stop.await_count == 1


def test_resumes_only_after_green_and_an_advancing_tip(tmp_path):
    gate, docker, clock = _gate(tmp_path)
    _run(gate, clock, RED, mg.SUPPRESS_AFTER_SEC)
    suspended_at = gate._since
    # green with no tip movement since suspension (e.g. a fresh verdict): stay suspended
    assert (
        _run(gate, clock, GREEN, 2 * mg.RESUME_AFTER_SEC, advanced_at=suspended_at - 1)
        == "suppressed"
    )
    assert _run(gate, clock, GREEN, mg.RESUME_AFTER_SEC, advanced_at=clock.t) == "on"
    assert not (tmp_path / mg.MARKER).exists()
    assert docker.start.await_count == 2  # once to suspend, once to resume


def test_amber_neither_suspends_nor_resumes(tmp_path):
    gate, docker, clock = _gate(tmp_path)
    assert _run(gate, clock, {"level": "amber"}, 3600) == "on"
    docker.stop.assert_not_awaited()


def test_held_p2pool_is_not_started_the_marker_alone_changes(tmp_path):
    """The sync gate or fail-closed hold owns p2pool's start; it reads the marker when it starts."""
    gate, docker, clock = _gate(tmp_path)
    assert _run(gate, clock, RED, mg.SUPPRESS_AFTER_SEC, running=False) == "suppressed"
    assert (tmp_path / mg.MARKER).exists()
    docker.start.assert_not_awaited()


def test_a_restart_that_failed_is_retried(tmp_path):
    gate, docker, clock = _gate(tmp_path, ok=False)
    _run(gate, clock, RED, mg.SUPPRESS_AFTER_SEC)
    docker.start.return_value = docker.stop.return_value = True
    _run(gate, clock, RED, 0)
    assert docker.start.await_count == 2


def test_a_marker_left_by_a_previous_run_is_honoured(tmp_path):
    (tmp_path / mg.MARKER).write_text("x")
    gate, docker, clock = _gate(tmp_path)
    assert _run(gate, clock, GREEN, 60) == "suppressed"


def _red_at(h):
    return {**RED, "height": h}


def _green_at(h):
    return {**GREEN, "height": h}


def test_recovery_that_stays_below_the_suppression_height_keeps_merge_mining_off(tmp_path):
    """A rewound or reset node can be green again while still behind the tip it went stale at."""
    gate, docker, clock = _gate(tmp_path)
    _run(gate, clock, _red_at(500), mg.SUPPRESS_AFTER_SEC)
    assert (tmp_path / mg.MARKER).read_text().startswith("height=500\n")
    assert (
        _run(gate, clock, _green_at(480), 3 * mg.RESUME_AFTER_SEC, advanced_at=clock.t)
        == "suppressed"
    )
    assert (
        _run(gate, clock, _green_at(500), 3 * mg.RESUME_AFTER_SEC, advanced_at=clock.t)
        == "suppressed"
    )
    assert _run(gate, clock, _green_at(501), mg.RESUME_AFTER_SEC, advanced_at=clock.t) == "on"


def test_the_suppression_height_survives_a_dashboard_restart(tmp_path):
    gate, docker, clock = _gate(tmp_path)
    _run(gate, clock, _red_at(500), mg.SUPPRESS_AFTER_SEC)
    fresh, _, fclock = _gate(tmp_path)  # a new dashboard: green only because it has no history
    assert (
        _run(fresh, fclock, _green_at(499), 3 * mg.RESUME_AFTER_SEC, advanced_at=fclock.t)
        == "suppressed"
    )
    assert _run(fresh, fclock, _green_at(505), mg.RESUME_AFTER_SEC, advanced_at=fclock.t) == "on"
