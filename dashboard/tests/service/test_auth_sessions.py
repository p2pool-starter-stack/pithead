import pytest

from mining_dashboard.service import auth_sessions
from mining_dashboard.service.storage_service import StateManager


class TestSessionLifetimes:
    @pytest.fixture
    def store(self):
        sm = StateManager(db_path=":memory:")
        auth_sessions.create_schema(sm)
        yield sm
        sm.close()

    @pytest.fixture
    def clock(self, monkeypatch):
        now = [1_000_000.0]
        monkeypatch.setattr(auth_sessions.time, "time", lambda: now[0])
        return now

    def test_unremembered_session_expires_after_idle_timeout(self, store, clock):
        token = auth_sessions.issue(store, "admin", "e", False)
        clock[0] += auth_sessions.IDLE_SECONDS - 5
        assert auth_sessions.validate(store, token, "e")[0] == "admin"
        clock[0] += auth_sessions.IDLE_SECONDS - 5
        assert auth_sessions.validate(store, token, "e")[0] == "admin"
        clock[0] += auth_sessions.IDLE_SECONDS + 5
        assert auth_sessions.validate(store, token, "e") is None

    def test_remembered_session_outlives_the_idle_timeout(self, store, clock):
        token = auth_sessions.issue(store, "admin", "e", True)
        clock[0] += auth_sessions.IDLE_SECONDS * 3
        assert auth_sessions.validate(store, token, "e") is not None

    def test_remembered_session_lasts_thirty_days_unused(self, store, clock):
        token = auth_sessions.issue(store, "admin", "e", True)
        clock[0] += 30 * 86400 - 5
        assert auth_sessions.validate(store, token, "e") is not None
        clock[0] += 30 * 86400 + 5
        assert auth_sessions.validate(store, token, "e") is None

    def test_use_slides_the_remembered_window_and_asks_for_a_cookie_refresh(self, store, clock):
        token = auth_sessions.issue(store, "admin", "e", True)
        clock[0] += 20 * 86400
        _, _, refresh = auth_sessions.validate(store, token, "e")
        assert refresh is True
        clock[0] += 20 * 86400
        assert auth_sessions.validate(store, token, "e") is not None

    def test_no_cookie_refresh_within_a_day(self, store, clock):
        token = auth_sessions.issue(store, "admin", "e", True)
        clock[0] += 3600
        assert auth_sessions.validate(store, token, "e")[2] is False

    def test_unremembered_sessions_never_ask_for_a_persistent_cookie(self, store, clock):
        token = auth_sessions.issue(store, "admin", "e", False)
        clock[0] += 2 * 86400 // 8
        assert auth_sessions.validate(store, token, "e")[2] is False

    def test_session_table_is_capped(self, store, clock):
        for _ in range(auth_sessions.MAX_SESSIONS + 5):
            clock[0] += 1
            auth_sessions.issue(store, "admin", "e", False)
        count = store._conn.execute("SELECT COUNT(*) FROM dashboard_sessions").fetchone()[0]
        assert count == auth_sessions.MAX_SESSIONS

    def test_tokens_are_stored_hashed(self, store):
        token = auth_sessions.issue(store, "admin", "e", False)
        ids = [r["id"] for r in store._conn.execute("SELECT id FROM dashboard_sessions")]
        assert token not in ids
