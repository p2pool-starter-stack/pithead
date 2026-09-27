"""TariMergeMineGate (#2464): red stops Tari merge-mining without stopping Monero; recovery resumes it."""

import asyncio
import os
import time
from unittest.mock import AsyncMock

from mining_dashboard.service.health import owed_start
from mining_dashboard.service.health import tari_merge_gate as mg
from mining_dashboard.service.health.tari_merge_gate import TariMergeMineGate
from tests.service.health.test_owed_start import age_record

RED = {"level": "red", "reasons": ["tip 1 unchanged for 30 min"]}
GREEN = {"level": "green", "reasons": []}


class Clock:
    t = 1000.0

    def __call__(self):
        return self.t


class P2Pool:
    """A p2pool container on the host clock: ``StartedAt`` moves when a start lands."""

    def __init__(self, started_at=None, running=True, ok=True):
        self.started_at = time.time() - 3600 if started_at is None else started_at
        self.running = running
        self.docker = AsyncMock()
        self.docker.stop.side_effect = self._stop
        self.docker.start.side_effect = self._start
        self.stop_ok = self.start_ok = ok

    async def _stop(self, name, **kw):
        if self.stop_ok:
            self.running = False
        return self.stop_ok

    async def _start(self, name, **kw):
        if self.start_ok and not self.running:
            self.running, self.started_at = True, time.time() + 0.001
        return self.start_ok

    async def inspect(self, name):
        return self.running, self.started_at


def _gate(tmp_path, p2pool=None):
    p2pool = p2pool or P2Pool()
    clock = Clock()
    gate = TariMergeMineGate(str(tmp_path), p2pool.docker, clock=clock, inspect=p2pool.inspect)
    return gate, p2pool, clock


def _run(gate, clock, verdict, seconds, running=True):
    out = None
    for _ in range(int(seconds // 60) + 1):
        out = asyncio.run(gate.apply(verdict, running))
        clock.t += 60
    return out


def _red_at(h):
    return {**RED, "height": h}


def _green_at(h, explorer_tip=None):
    return {**GREEN, "height": h, "explorer_tip": explorer_tip}


def test_sustained_red_suspends_merge_mining_and_relaunches_only_p2pool(tmp_path):
    """Covers auto-restart off or exhausted too: the gate reads the verdict, never the restart."""
    gate, p2pool, clock = _gate(tmp_path)
    assert _run(gate, clock, _red_at(1), mg.SUPPRESS_AFTER_SEC - 60) == "on"
    assert _run(gate, clock, _red_at(1), 60) == "suppressed"
    assert (tmp_path / mg.MARKER).exists()
    p2pool.docker.stop.assert_awaited_once()
    assert p2pool.docker.stop.await_args.args[0] == "p2pool"
    assert p2pool.docker.start.await_args.args[0] == "p2pool"
    _run(gate, clock, _red_at(1), 3600)  # a red that lasts: no further restarts
    assert p2pool.docker.stop.await_count == 1
    assert sorted(os.listdir(tmp_path)) == [mg.MARKER]  # no temp file, no owed start left behind


def test_resumes_only_after_green_past_the_suppression_height(tmp_path):
    gate, p2pool, clock = _gate(tmp_path)
    _run(gate, clock, _red_at(500), mg.SUPPRESS_AFTER_SEC)
    assert (tmp_path / mg.MARKER).read_text().startswith("height=500\n")
    assert _run(gate, clock, _green_at(480), 3 * mg.RESUME_AFTER_SEC) == "suppressed"  # rewound
    assert _run(gate, clock, _green_at(500), 3 * mg.RESUME_AFTER_SEC) == "suppressed"
    assert _run(gate, clock, _green_at(501), mg.RESUME_AFTER_SEC) == "on"
    assert not (tmp_path / mg.MARKER).exists()
    assert p2pool.docker.start.await_count == 2  # once to suspend, once to resume
    assert not (tmp_path / mg.RESUMED).exists()  # confirmed by the restart this gate made


def test_amber_neither_suspends_nor_resumes(tmp_path):
    gate, p2pool, clock = _gate(tmp_path)
    assert _run(gate, clock, {"level": "amber"}, 3600) == "on"
    p2pool.docker.stop.assert_not_awaited()


def test_held_p2pool_is_not_started_the_marker_alone_changes(tmp_path):
    """The sync gate or fail-closed hold owns p2pool's start; it reads the marker when it starts."""
    gate, p2pool, clock = _gate(tmp_path, P2Pool(running=False))
    assert _run(gate, clock, _red_at(1), mg.SUPPRESS_AFTER_SEC, running=False) == "suppressed"
    assert (tmp_path / mg.MARKER).exists()
    p2pool.docker.start.assert_not_awaited()


def test_a_stop_that_failed_is_retried(tmp_path):
    p2pool = P2Pool()
    p2pool.stop_ok = False
    gate, _, clock = _gate(tmp_path, p2pool)
    _run(gate, clock, _red_at(1), mg.SUPPRESS_AFTER_SEC)
    assert p2pool.running and (tmp_path / "p2pool-start-owed").exists()  # uncertain: kept
    p2pool.stop_ok = True
    _run(gate, clock, _red_at(1), 0)
    p2pool.docker.start.assert_not_awaited()  # still within the stop's grace: maybe stopping
    age_record(tmp_path / "p2pool-start-owed", mg.STOP_REQUEST_SEC + 1)
    _run(gate, clock, _red_at(1), 0)  # running past the grace: the stop never landed; again
    assert p2pool.docker.start.await_count == 1 and p2pool.started_at > time.time() - 60
    assert not (tmp_path / "p2pool-start-owed").exists() and not gate._launch_unconfirmed


def test_the_suppression_height_survives_a_dashboard_restart(tmp_path):
    gate, p2pool, clock = _gate(tmp_path)
    _run(gate, clock, _red_at(500), mg.SUPPRESS_AFTER_SEC)
    fresh, _, fclock = _gate(tmp_path, p2pool)  # a new dashboard: green only as it has no history
    assert _run(fresh, fclock, _green_at(499), 3 * mg.RESUME_AFTER_SEC) == "suppressed"
    assert _run(fresh, fclock, _green_at(505), mg.RESUME_AFTER_SEC) == "on"


# --- interruptions (#2464 review round 4) ------------------------------------------------------


def test_dashboard_restart_relaunches_a_p2pool_still_running_from_before_the_marker(tmp_path):
    """The marker was written, then the dashboard died before p2pool restarted: p2pool still
    merge-mines the stale tip. A new dashboard sees a launch older than the marker and restarts."""
    p2pool = P2Pool()
    gate, _, clock = _gate(tmp_path, p2pool)
    assert gate._set_marker(True, 500)  # the write landed; the restart never did
    fresh, _, fclock = _gate(tmp_path, p2pool)
    assert _run(fresh, fclock, _red_at(500), 0) == "suppressed"
    p2pool.docker.stop.assert_awaited_once()
    assert p2pool.started_at > os.path.getmtime(tmp_path / mg.MARKER)
    _run(fresh, fclock, _red_at(500), 600)
    assert p2pool.docker.stop.await_count == 1  # confirmed: never again


def test_dashboard_restart_leaves_a_p2pool_launched_after_the_marker_alone(tmp_path):
    (tmp_path / mg.MARKER).write_text("height=500\n")
    gate, p2pool, clock = _gate(tmp_path, P2Pool(started_at=time.time() + 1))
    _run(gate, clock, _red_at(500), 600)
    p2pool.docker.stop.assert_not_awaited()


def test_dashboard_restart_relaunches_p2pool_left_without_merge_mining_after_resume(tmp_path):
    p2pool = P2Pool()
    gate, _, clock = _gate(tmp_path, p2pool)
    gate._set_marker(True, 500)
    gate.suppressed = True
    assert gate._set_marker(False)  # marker gone, the dashboard died before the restart
    fresh, _, fclock = _gate(tmp_path, p2pool)
    assert _run(fresh, fclock, _green_at(600), 0) == "on"
    p2pool.docker.stop.assert_awaited_once()
    assert not (tmp_path / mg.RESUMED).exists()


def test_a_p2pool_this_gate_stopped_but_could_not_start_is_started_after_a_dashboard_restart(
    tmp_path,
):
    p2pool = P2Pool()
    p2pool.start_ok = False
    gate, _, clock = _gate(tmp_path, p2pool)
    _run(gate, clock, _red_at(1), mg.SUPPRESS_AFTER_SEC)
    assert not p2pool.running and (tmp_path / "p2pool-start-owed").exists()
    p2pool.start_ok = True
    fresh, _, fclock = _gate(tmp_path, p2pool)  # the in-memory retry died with the old dashboard
    _run(fresh, fclock, _red_at(1), 0)
    assert p2pool.running and not (tmp_path / "p2pool-start-owed").exists()
    assert p2pool.docker.stop.await_count == 1  # started, not restarted again


def test_an_owed_start_is_dropped_when_someone_else_started_p2pool_since(tmp_path):
    """The operator started (and perhaps stopped) p2pool after this gate's stop: it owes nothing."""
    p2pool = P2Pool()
    p2pool.start_ok = False
    gate, _, clock = _gate(tmp_path, p2pool)
    _run(gate, clock, _red_at(1), mg.SUPPRESS_AFTER_SEC)
    p2pool.started_at, p2pool.running = time.time() + 1, False  # started then stopped by hand
    p2pool.start_ok = True
    _run(gate, clock, _red_at(1), 600)
    assert not p2pool.running and not (tmp_path / "p2pool-start-owed").exists()


def test_a_held_p2pool_owed_a_start_is_left_to_the_gate_that_holds_it(tmp_path):
    p2pool = P2Pool()
    p2pool.start_ok = False
    gate, _, clock = _gate(tmp_path, p2pool)
    _run(gate, clock, _red_at(1), mg.SUPPRESS_AFTER_SEC)
    p2pool.start_ok = True
    _run(gate, clock, _red_at(1), 600, running=False)
    assert not p2pool.running


def test_an_unreadable_container_state_changes_nothing_until_it_reads(tmp_path):
    (tmp_path / mg.MARKER).write_text("height=500\n")
    p2pool = P2Pool()
    gate, _, clock = _gate(tmp_path, p2pool)
    gate._inspect = AsyncMock(return_value=None)
    _run(gate, clock, _red_at(500), 600)
    p2pool.docker.stop.assert_not_awaited()
    gate._inspect = p2pool.inspect
    _run(gate, clock, _red_at(500), 0)
    p2pool.docker.stop.assert_awaited_once()


# --- the marker: atomic, fail-closed ------------------------------------------------------------


def test_an_empty_or_invalid_marker_fails_closed(tmp_path):
    """No height stands in for an unreadable one: the node's own green, at any height, is not
    enough. Only a green measured against the public explorer resumes."""
    for content in ("", "x", "height=\n", "height=abc\n"):
        (tmp_path / mg.MARKER).write_text(content)
        gate, p2pool, clock = _gate(tmp_path, P2Pool(started_at=time.time() + 1))
        assert _run(gate, clock, _green_at(10**9), 3 * mg.RESUME_AFTER_SEC) == "suppressed"
        assert _run(gate, clock, _green_at(10**9, explorer_tip=10**9), 0) == "suppressed"
        assert _run(gate, clock, _green_at(10**9, explorer_tip=10**9), 300) == "on"


def test_an_interrupted_marker_write_leaves_no_marker_and_is_retried(tmp_path, monkeypatch):
    """The process dies (here: the disk fills) after the file is opened, before it is written."""
    gate, p2pool, clock = _gate(tmp_path)

    class Crashing:
        def __init__(self, fh):
            self._fh = fh

        def __enter__(self):
            return self

        def __exit__(self, *exc):
            self._fh.close()

        def write(self, text):
            raise OSError("disk full")

    monkeypatch.setattr(owed_start, "open", lambda *a: Crashing(open(*a)), raising=False)
    assert _run(gate, clock, _red_at(500), mg.SUPPRESS_AFTER_SEC) == "on"
    assert not (tmp_path / mg.MARKER).exists()  # never an empty or partial marker
    p2pool.docker.stop.assert_not_awaited()
    monkeypatch.undo()
    assert _run(gate, clock, _red_at(500), 0) == "suppressed"
    assert (tmp_path / mg.MARKER).read_text().startswith("height=500\n")


# --- the owed-start record cannot be written (#2464 review round 5) -----------------------------


def test_an_unrecordable_owed_start_stops_nothing_and_stays_unconfirmed(tmp_path, monkeypatch):
    """A stop with no durable record could leave p2pool stopped, and a later cycle would see it
    stopped and call the launch reconciled. So p2pool is not stopped, across a dashboard restart
    too, until the record can be written; then the relaunch completes."""
    p2pool = P2Pool()
    p2pool.start_ok = False  # the worst case: a stop now would strand it
    gate, _, clock = _gate(tmp_path, p2pool)
    assert gate._set_marker(True, 500)
    real, full = owed_start.write_atomic, [True]

    def write(path, text):
        if full[0]:
            raise OSError(30, "Read-only file system")
        real(path, text)

    monkeypatch.setattr(owed_start, "write_atomic", write)
    for fresh in (False, True):  # this dashboard, then a restarted one
        if fresh:
            gate, _, clock = _gate(tmp_path, p2pool)
        _run(gate, clock, _red_at(500), 600)
        assert p2pool.running and gate._launch_unconfirmed
        p2pool.docker.stop.assert_not_awaited()
    full[0] = False
    p2pool.start_ok = True
    _run(gate, clock, _red_at(500), 0)
    assert p2pool.running and p2pool.started_at > os.path.getmtime(tmp_path / mg.MARKER)
    assert not gate._launch_unconfirmed and not (tmp_path / "p2pool-start-owed").exists()


# --- a stop whose acknowledgement was lost (#2464 review round 6) -------------------------------


def test_a_lost_stop_acknowledgement_leaves_p2pool_owed_across_a_dashboard_restart(tmp_path):
    """The stop landed but came back False. Settling on that would leave p2pool stopped, and the
    next cycle, seeing it stopped, would call the launch reconciled: Monero mining gone."""
    p2pool = P2Pool()

    async def lost_ack(name, **kw):
        p2pool.running = False
        return False

    p2pool.docker.stop.side_effect = lost_ack
    p2pool.start_ok = False
    gate, _, clock = _gate(tmp_path, p2pool)
    _run(gate, clock, _red_at(500), mg.SUPPRESS_AFTER_SEC + 120)
    assert not p2pool.running and (tmp_path / "p2pool-start-owed").exists()
    assert gate._launch_unconfirmed and p2pool.docker.start.await_count >= 1  # retried
    p2pool.start_ok = True
    fresh, _, fclock = _gate(tmp_path, p2pool)  # a new dashboard picks the owed start up
    _run(fresh, fclock, _red_at(500), 0)
    assert p2pool.running and p2pool.started_at > os.path.getmtime(tmp_path / mg.MARKER)
    assert not (tmp_path / "p2pool-start-owed").exists() and not fresh._launch_unconfirmed
