"""Tari chain health (#2464): the start-only retry owed to a node a restart stopped but could not
start. It is kept on disk, so a dashboard restart resumes it without starting a node someone else
has started (or stopped) since, and without ever stopping one."""

import asyncio
import os
import time

from mining_dashboard.service.health import owed_start
from mining_dashboard.service.health import tari_health as th
from tests.service.health.test_tari_health import MIN, SYNCED, Clock, _docker, _monitor

# --- split restart: stopped, then not started (#2464 review) ------------------------------------


def test_a_stop_that_landed_and_a_start_that_failed_gets_bounded_start_retries():
    """The node this code stopped has silent gRPC because it is stopped, not migrating: start it."""
    clock, docker = Clock(), _docker()
    docker.start.return_value = False
    mon = _monitor(docker_control=docker, clock=clock)
    for _ in range(36):
        v = asyncio.run(mon.check(SYNCED, 0))
        clock.t += MIN
    assert v["action"] == "start_failed" and v["advice"] == th.STOPPED_ADVICE
    down = {"reachable": False}
    actions = []
    for _ in range(th.START_RETRIES * 2 + 2):
        actions.append(asyncio.run(mon.check(down, None))["action"])
        clock.t += MIN
    assert docker.stop.await_count == 1  # never another stop
    assert docker.start.await_count == 1 + th.START_RETRIES  # bounded
    assert actions[-1] == "start_gave_up"  # and it stays given up: no restart of a stopped node
    assert asyncio.run(mon.check(down, None))["advice"] == th.STOPPED_ADVICE


def test_a_start_retry_that_succeeds_hands_back_to_the_migration_guard():
    clock, docker = Clock(), _docker()
    docker.start.side_effect = [False, True]
    mon = _monitor(docker_control=docker, clock=clock)
    for _ in range(36):
        asyncio.run(mon.check(SYNCED, 0))
        clock.t += MIN
    clock.t += th.START_RETRY_SEC
    assert asyncio.run(mon.check({"reachable": False}, None))["action"] == "started"
    clock.t += MIN
    v = asyncio.run(mon.check({"reachable": False}, None))
    assert (
        v["action"] == "withheld" and v["advice"] != th.STOPPED_ADVICE
    )  # a started node may migrate


# --- a dashboard restart between the stop and a successful start (#2464 review round 4) ---------


def _stranded_by_a_failed_start(state_dir):
    clock, docker = Clock(), _docker()
    docker.start.return_value = False
    mon = _monitor(docker_control=docker, clock=clock, state_dir=state_dir)
    for _ in range(36):
        v = asyncio.run(mon.check(SYNCED, 0))
        clock.t += MIN
    assert v["action"] == "start_failed"
    return docker


def test_a_dashboard_restart_resumes_the_start_owed_to_a_node_it_stopped(tmp_path):
    """Before: the owed start lived in memory, so a new dashboard saw a silent gRPC, called it a
    migration and withheld forever. The record on disk hands the retry to the new process."""
    docker = _stranded_by_a_failed_start(str(tmp_path))
    docker.start.return_value = True
    mon = _monitor(docker_control=docker, clock=Clock(), state_dir=str(tmp_path))
    v = asyncio.run(mon.check({"reachable": False}, None))
    assert v["action"] == "started" and docker.stop.await_count == 1
    assert os.listdir(tmp_path) == []


def test_the_start_retry_limit_survives_a_dashboard_restart(tmp_path):
    docker = _stranded_by_a_failed_start(str(tmp_path))
    clock = Clock()
    mon = _monitor(docker_control=docker, clock=clock, state_dir=str(tmp_path))
    for _ in range(2):
        asyncio.run(mon.check({"reachable": False}, None))
        clock.t += th.START_RETRY_SEC
    mon = _monitor(docker_control=docker, clock=Clock(), state_dir=str(tmp_path))
    actions = []
    for _ in range(2 * th.START_RETRIES):
        actions.append(asyncio.run(mon.check({"reachable": False}, None))["action"])
        mon._clock.t += th.START_RETRY_SEC
    assert docker.start.await_count == 1 + th.START_RETRIES  # the new dashboard spent only the rest
    assert actions[-1] == "start_gave_up" and docker.stop.await_count == 1


def test_a_node_started_since_the_stop_is_never_started_again(tmp_path):
    """Someone started the node after this code stopped it (and may have stopped it on purpose):
    the record is dropped and the node's state is theirs; the migration guard applies again."""
    docker = _stranded_by_a_failed_start(str(tmp_path))

    async def started_by_hand(name):
        return False, time.time() + 1

    mon = _monitor(
        docker_control=docker, clock=Clock(), state_dir=str(tmp_path), inspect=started_by_hand
    )
    v = asyncio.run(mon.check({"reachable": False}, None))
    assert v["action"] == "start_settled" and v["advice"] != th.STOPPED_ADVICE
    assert docker.start.await_count == 1 and os.listdir(tmp_path) == []


def test_a_running_node_with_silent_grpc_is_left_to_migrate(tmp_path):
    docker = _stranded_by_a_failed_start(str(tmp_path))

    async def running(name):
        return True, time.time() - 3600

    mon = _monitor(docker_control=docker, clock=Clock(), state_dir=str(tmp_path), inspect=running)
    assert asyncio.run(mon.check({"reachable": False}, None))["action"] == "start_settled"
    assert docker.start.await_count == 1 and docker.stop.await_count == 1


def test_an_unreadable_container_state_starts_nothing(tmp_path):
    docker = _stranded_by_a_failed_start(str(tmp_path))

    async def unreadable(name):
        return None

    mon = _monitor(
        docker_control=docker, clock=Clock(), state_dir=str(tmp_path), inspect=unreadable
    )
    v = asyncio.run(mon.check({"reachable": False}, None))
    assert v["action"] == "start_pending" and v["advice"] == th.STOPPED_ADVICE
    assert docker.start.await_count == 1


def test_a_dashboard_restart_between_stop_and_start_still_owes_the_start(tmp_path):
    """The record is written before the stop, so a process that died mid-restart left it."""
    clock, docker = Clock(), _docker()
    mon = _monitor(docker_control=docker, clock=clock, state_dir=str(tmp_path))

    async def die_after_the_stop(name, **kw):
        raise SystemExit

    docker.start.side_effect = die_after_the_stop
    try:
        for _ in range(36):
            asyncio.run(mon.check(SYNCED, 0))
            clock.t += MIN
    except SystemExit:
        pass
    assert os.listdir(tmp_path) == ["tari-start-owed"]
    docker.start.side_effect, docker.start.return_value = None, True
    mon = _monitor(docker_control=docker, clock=Clock(), state_dir=str(tmp_path))
    assert asyncio.run(mon.check({"reachable": False}, None))["action"] == "started"


# --- the record cannot be written (#2464 review round 5) ----------------------------------------


class Disk:
    """``write_atomic`` for the owed-start record, failing while ``full`` (a full or read-only
    state directory)."""

    def __init__(self, monkeypatch, full=True):
        self.full = full
        real = owed_start.write_atomic
        monkeypatch.setattr(owed_start, "write_atomic", lambda p, t: self._write(real, p, t))

    def _write(self, real, path, text):
        if self.full:
            raise OSError(28, "No space left on device")
        real(path, text)


def _red_cycles(mon, clock, sync=SYNCED, cycles=36):
    actions = []
    for _ in range(cycles):
        actions.append(asyncio.run(mon.check(sync, 0))["action"])
        clock.t += MIN
    return actions


def test_an_unrecordable_restart_never_stops_the_node_across_a_dashboard_restart(
    tmp_path, monkeypatch
):
    """Without a durable record a stop could strand the node (its start failing, the retry lost
    with the process). So no record, no stop: the slot comes back and the advice says why."""
    disk, docker = Disk(monkeypatch), _docker()
    docker.start.return_value = False  # the worst case: a stop now would leave it stopped
    clock = Clock()
    mon = _monitor(docker_control=docker, clock=clock, state_dir=str(tmp_path))
    actions = _red_cycles(mon, clock)
    assert "restart_unrecorded" in actions and mon.verdict["restarts"] == 0
    assert mon.verdict["advice"] == th.UNRECORDED_ADVICE
    docker.stop.assert_not_awaited()
    clock = Clock()  # a new dashboard, the disk still full: still nothing stopped
    mon = _monitor(docker_control=docker, clock=clock, state_dir=str(tmp_path))
    _red_cycles(mon, clock)
    docker.stop.assert_not_awaited()
    disk.full = False  # the disk recovers: the restart goes ahead, and its failed start is owed
    actions = _red_cycles(mon, clock, cycles=1)
    assert actions == ["start_failed"] and os.listdir(tmp_path) == ["tari-start-owed"]
    clock.t += th.START_RETRY_SEC
    docker.start.return_value = True
    assert asyncio.run(mon.check({"reachable": False}, None))["action"] == "started"


def test_the_retry_limit_holds_in_process_when_a_spent_retry_cannot_be_recorded(
    tmp_path, monkeypatch
):
    docker = _docker()
    docker.start.return_value = False
    clock = Clock()
    mon = _monitor(docker_control=docker, clock=clock, state_dir=str(tmp_path))
    assert _red_cycles(mon, clock)[-1] == "start_failed"
    Disk(monkeypatch)  # every later write fails: the file keeps START_RETRIES
    actions = []
    for _ in range(3 * th.START_RETRIES):
        clock.t += th.START_RETRY_SEC
        actions.append(asyncio.run(mon.check({"reachable": False}, None))["action"])
    assert docker.start.await_count == 1 + th.START_RETRIES and actions[-1] == "start_gave_up"
    mon = _monitor(docker_control=docker, clock=Clock(), state_dir=str(tmp_path))
    asyncio.run(mon.check({"reachable": False}, None))  # a new dashboard is not stranded either
    assert docker.start.await_count == 2 + th.START_RETRIES and docker.stop.await_count == 1
