import pytest

from mining_dashboard.service.workers import worker_config_store as wcs


class _Conn:
    def __init__(self, conn):
        self._conn = conn
        self.writes = 0
        self.commits = 0

    def execute(self, sql, *args):
        if sql.lstrip().upper().startswith(("INSERT", "UPDATE", "DELETE")):
            self.writes += 1
        return self._conn.execute(sql, *args)

    def commit(self):
        self.commits += 1
        return self._conn.commit()

    def __getattr__(self, name):
        return getattr(self._conn, name)


class _Clock:
    def __init__(self, now):
        self.now = now

    def time(self):
        return self.now


def _meta(revision, change_id=None):
    return {"revision": revision, "last_change_id": change_id}


@pytest.fixture
def clock(monkeypatch):
    c = _Clock(1_000_000.0)
    monkeypatch.setattr(wcs, "time", c)
    return c


@pytest.fixture
def spy(state_manager):
    s = _Conn(state_manager._conn)
    state_manager._conn = s
    return s


def _row(sm):
    return sm._conn.execute(
        "SELECT revision, last_change_id, ts, drift_from, rigforge_version "
        "FROM worker_config_revision WHERE worker = 'rig1'"
    ).fetchone()


class TestUnchangedPollsDoNotWrite:
    def test_second_identical_poll_does_not_write(self, state_manager, spy, clock):
        state_manager.note_worker_revision("rig1", _meta("aaa", "c1"), "1.0.0")
        assert (spy.writes, spy.commits) == (1, 1)
        clock.now += 30
        assert state_manager.note_worker_revision("rig1", _meta("aaa", "c1"), "1.0.0") is None
        assert (spy.writes, spy.commits) == (1, 1)
        assert _row(state_manager)["ts"] == 1_000_000.0

    def test_a_revision_move_is_written_and_returned_in_the_same_poll(
        self, state_manager, spy, clock
    ):
        state_manager.note_worker_revision("rig1", _meta("aaa"))
        clock.now += 30
        assert state_manager.note_worker_revision("rig1", _meta("bbb")) == {
            "worker": "rig1",
            "before": "aaa",
            "after": "bbb",
        }
        assert (spy.writes, spy.commits) == (2, 2)
        assert _row(state_manager)["revision"] == "bbb"

    def test_a_change_id_move_is_written_in_the_same_poll(self, state_manager, spy, clock):
        state_manager.note_worker_revision("rig1", _meta("aaa", "c1"))
        clock.now += 30
        state_manager.note_worker_revision("rig1", _meta("aaa", "c2"))
        assert (spy.writes, spy.commits) == (2, 2)
        assert _row(state_manager)["last_change_id"] == "c2"

    def test_a_version_move_is_written_in_the_same_poll(self, state_manager, spy, clock):
        state_manager.note_worker_revision("rig1", _meta("aaa"), "1.0.0")
        clock.now += 30
        state_manager.note_worker_revision("rig1", _meta("aaa"), "1.1.0")
        assert (spy.writes, spy.commits) == (2, 2)
        assert _row(state_manager)["rigforge_version"] == "1.1.0"

    def test_drift_from_survives_unchanged_polls(self, state_manager, spy, clock):
        state_manager.note_worker_revision("rig1", _meta("aaa"))
        state_manager.note_worker_revision("rig1", _meta("bbb"))
        writes = spy.writes
        for _ in range(3):
            clock.now += 30
            assert state_manager.note_worker_revision("rig1", _meta("bbb")) is None
        assert spy.writes == writes
        assert _row(state_manager)["drift_from"] == "aaa"
        assert state_manager.get_worker_revision_drift("rig1", "bbb") == {
            "worker": "rig1",
            "before": "aaa",
            "after": "bbb",
        }

    def test_drift_from_going_quiet_is_written(self, state_manager, spy, clock):
        state_manager.note_worker_revision("rig1", _meta("aaa"))
        state_manager.note_worker_revision("rig1", _meta("bbb"))
        clock.now += 30
        state_manager.note_worker_revision("rig1", _meta("ccc", "c1"))
        assert _row(state_manager)["drift_from"] is None
        assert state_manager.get_worker_revision_drift("rig1", "ccc") is None


class TestTheRowIsRefreshedBeforeThePrune:
    def test_refresh_happens_once_the_bound_has_passed(self, state_manager, spy, clock):
        state_manager.note_worker_revision("rig1", _meta("aaa"))
        clock.now += wcs._REVISION_REFRESH_SEC - 1
        state_manager.note_worker_revision("rig1", _meta("aaa"))
        assert spy.commits == 1
        clock.now += 1
        state_manager.note_worker_revision("rig1", _meta("aaa"))
        assert spy.commits == 2
        assert _row(state_manager)["ts"] == clock.now

    def test_a_future_ts_is_refreshed(self, state_manager, spy, clock):
        state_manager.note_worker_revision("rig1", _meta("aaa"))
        clock.now -= 600
        state_manager.note_worker_revision("rig1", _meta("aaa"))
        assert spy.commits == 2
        assert _row(state_manager)["ts"] == clock.now

    def test_a_row_whose_ts_is_not_a_number_is_rewritten(self, state_manager, spy, clock):
        state_manager.note_worker_revision("rig1", _meta("aaa"))
        state_manager._conn.execute("UPDATE worker_config_revision SET ts = NULL")
        commits = spy.commits
        state_manager.note_worker_revision("rig1", _meta("aaa"))
        assert spy.commits == commits + 1
        assert _row(state_manager)["ts"] == clock.now
