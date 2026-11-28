from unittest.mock import patch

from mining_dashboard.service.storage_service import StateManager


class Clock:
    def __init__(self, t=1000.0):
        self.t = t

    def __call__(self):
        return self.t

    def advance(self, seconds):
        self.t += seconds


def _sm(clock=None):
    sm = StateManager(db_path=":memory:")
    return sm


def _patch_time(clock):
    patcher = patch("mining_dashboard.service.event_log_store.time", _FakeTime(clock))
    patcher.start()
    return patcher


class _FakeTime:
    def __init__(self, clock):
        self._clock = clock

    def time(self):
        return self._clock()


def test_error_opens_episode():
    clock = Clock()
    sm = _sm(clock)
    p = _patch_time(clock)
    try:
        sm.record_event("connect", "pool", "Connect to pool", "error", "connection refused", {})
        episodes = sm.get_open_episodes()
        assert len(episodes) == 1
        assert episodes[0]["kind"] == "connect"
        assert episodes[0]["subject"] == "pool"
        assert episodes[0]["count"] == 1
        assert episodes[0]["end_ts"] is None
    finally:
        p.stop()
    sm.close()


def test_normal_event_does_not_open_episode():
    sm = StateManager(db_path=":memory:")
    sm.record_event("connect", "pool", "Connect to pool", "normal", "connected", {})
    assert len(sm.get_open_episodes()) == 0
    sm.close()


def test_repeat_increments_count_and_updates_ts():
    clock = Clock()
    sm = _sm(clock)
    p = _patch_time(clock)
    try:
        sm.record_event("connect", "pool", "Connect to pool", "error", "connection refused", {})
        clock.advance(60)
        sm.record_event("connect", "pool", "Connect to pool", "error", "connection refused", {})
        episodes = sm.get_open_episodes()
        assert len(episodes) == 1
        assert episodes[0]["count"] == 2
    finally:
        p.stop()
    sm.close()


def test_repeat_bypasses_per_minute_rate_limit():
    clock = Clock()
    sm = _sm(clock)
    p = _patch_time(clock)
    try:
        sm.record_event("connect", "pool", "Connect to pool", "error", "connection refused", {})
        clock.advance(5)
        sm.record_event("connect", "pool", "Connect to pool", "error", "connection refused", {})
        episodes = sm.get_open_episodes()
        assert len(episodes) == 1
        assert episodes[0]["count"] == 2
    finally:
        p.stop()
    sm.close()


def test_close_by_success():
    clock = Clock()
    sm = _sm(clock)
    p = _patch_time(clock)
    try:
        sm.record_event("connect", "pool", "Connect to pool", "error", "connection refused", {})
        clock.advance(30)
        sm.record_event("connect", "pool", "Connect to pool", "normal", "connected", {})
        episodes = sm.get_open_episodes()
        assert len(episodes) == 0
    finally:
        p.stop()
    sm.close()


def test_close_by_success_different_kind_does_not_close():
    clock = Clock()
    sm = _sm(clock)
    p = _patch_time(clock)
    try:
        sm.record_event("connect", "pool", "Connect to pool", "error", "connection refused", {})
        clock.advance(30)
        sm.record_event("sync", "chain", "Sync chain", "normal", "synced", {})
        episodes = sm.get_open_episodes()
        assert len(episodes) == 1
        assert episodes[0]["kind"] == "connect"
    finally:
        p.stop()
    sm.close()


def test_close_by_timeout():
    clock = Clock()
    sm = _sm(clock)
    p = _patch_time(clock)
    try:
        sm.record_event("connect", "pool", "Connect to pool", "error", "connection refused", {})
        clock.advance(30 * 60 + 1)
        assert sm.get_open_episodes() == []
        row = sm._conn.execute("SELECT ts, end_ts FROM event_log").fetchone()
        assert row["end_ts"] == row["ts"]
        sm.record_event("connect", "pool", "Connect to pool", "error", "connection refused", {})
        assert len(sm.get_open_episodes()) == 1
        assert sm._conn.execute("SELECT COUNT(*) FROM event_log").fetchone()[0] == 2
    finally:
        p.stop()
    sm.close()


def test_reopen_after_close_by_success():
    clock = Clock()
    sm = _sm(clock)
    p = _patch_time(clock)
    try:
        sm.record_event("connect", "pool", "Connect to pool", "error", "connection refused", {})
        clock.advance(30)
        sm.record_event("connect", "pool", "Connect to pool", "normal", "connected", {})
        clock.advance(10)
        sm.record_event("connect", "pool", "Connect to pool", "error", "reconnection failed", {})
        episodes = sm.get_open_episodes()
        assert len(episodes) == 1
        assert episodes[0]["count"] == 1
    finally:
        p.stop()
    sm.close()


def test_get_open_episodes_returns_open_only():
    clock = Clock()
    sm = _sm(clock)
    p = _patch_time(clock)
    try:
        sm.record_event("a", "x", "Err", "error", "err", {})
        sm.record_event("b", "y", "Err", "error", "err", {})
        clock.advance(30)
        sm.record_event("a", "x", "OK", "normal", "ok", {})
        episodes = sm.get_open_episodes()
        assert len(episodes) == 1
        assert episodes[0]["kind"] == "b"
    finally:
        p.stop()
    sm.close()


def test_episode_state_survives_restart(tmp_path):
    db = str(tmp_path / "restart.db")
    clock = Clock()
    p = _patch_time(clock)
    try:
        sm = StateManager(db_path=db)
        sm.record_event("connect", "pool", "Connect", "error", "refused", {})
        sm.close()

        sm2 = StateManager(db_path=db)
        episodes = sm2.get_open_episodes()
        assert len(episodes) == 1
        assert episodes[0]["kind"] == "connect"
        assert episodes[0]["subject"] == "pool"
        sm2.close()
    finally:
        p.stop()


def test_closed_connection_and_db_errors_are_tolerated():
    sm = _sm()
    sm.close()
    sm.record_event("connect", "pool", "Connect to pool", "error", "x", {})
    assert sm.get_open_episodes() == []
    sm2 = _sm()
    sm2._conn.execute("DROP TABLE event_log")
    sm2.record_event("connect", "pool", "Connect to pool", "error", "x", {})
    assert sm2.get_open_episodes() == []
    sm2.close()


def test_formatted_text_and_prune_sampler():
    sm = _sm()
    with patch("mining_dashboard.service.event_log_store.random.random", return_value=0.0):
        sm.record_event("connect", "pool", "Connect", "info", "to {host}", {"host": "a"})
    assert sm._conn.execute("SELECT text FROM event_log").fetchone()[0] == "to a"
    sm.close()


def test_load_tolerates_missing_event_log_table(tmp_path):
    db = str(tmp_path / "load.db")
    sm = StateManager(db_path=db)
    sm.record_event("connect", "pool", "Connect", "error", "refused", {})
    sm._conn.execute("DROP TABLE event_log")
    sm._conn.commit()
    sm.load()
    assert sm.state["event_log"] == []
    sm.close()
