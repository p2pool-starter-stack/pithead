import sqlite3
import threading

from mining_dashboard.service.storage_service import StateManager

NOW = 1_700_000_000.0


class TestXvbRowsKept:
    def statements(self, sm):
        seen = []
        sm._conn.set_trace_callback(seen.append)
        return seen

    def reads(self, seen):
        return [s for s in seen if "FROM xvb_history" in s]

    def test_second_read_does_not_touch_the_table(self, state_manager):
        state_manager.add_xvb_history(NOW, avg_1h=1.0)
        seen = self.statements(state_manager)
        first = state_manager.get_xvb_history()
        second = state_manager.get_xvb_history()
        assert first == second and len(first) == 1
        assert len(self.reads(seen)) == 1

    def test_insert_drops_the_kept_rows(self, state_manager):
        state_manager.add_xvb_history(NOW, avg_1h=1.0)
        assert len(state_manager.get_xvb_history()) == 1
        state_manager.add_xvb_history(NOW + 300, avg_1h=2.0)
        assert [r["avg_1h"] for r in state_manager.get_xvb_history()] == [1.0, 2.0]

    def test_failed_insert_still_drops_the_kept_rows(self, state_manager):
        state_manager.add_xvb_history(NOW, avg_1h=1.0)
        assert len(state_manager.get_xvb_history()) == 1
        with state_manager._db_lock:
            state_manager._conn.execute("DROP TABLE xvb_history")
        state_manager.add_xvb_history(NOW + 1)
        assert state_manager.get_xvb_history() == []

    def test_retention_delete_drops_the_kept_rows(self, state_manager, monkeypatch):
        monkeypatch.setattr("mining_dashboard.service.telemetry_store.random.random", lambda: 0.0)
        state_manager.add_xvb_history(NOW - 100 * 86400, avg_1h=9.0)
        assert len(state_manager.get_xvb_history()) == 1
        state_manager.add_xvb_history(NOW, avg_1h=1.0)
        assert [r["avg_1h"] for r in state_manager.get_xvb_history()] == [1.0]

    def test_recovered_database_is_not_served_from_the_old_rows(self, state_manager):
        state_manager.add_xvb_history(NOW, avg_1h=1.0)
        assert len(state_manager.get_xvb_history()) == 1
        state_manager._recover_corrupt_db("test: forced")
        assert state_manager.get_xvb_history() == []

    def test_closed_store_reads_empty(self, state_manager):
        state_manager.add_xvb_history(NOW, avg_1h=1.0)
        assert len(state_manager.get_xvb_history()) == 1
        state_manager.close()
        assert state_manager.get_xvb_history() == []

    def test_write_from_another_connection_is_seen(self, tmp_path):
        path = str(tmp_path / "state.db")
        sm = StateManager(db_path=path)
        try:
            sm.add_xvb_history(NOW, avg_1h=1.0)
            assert len(sm.get_xvb_history()) == 1
            other = sqlite3.connect(path)
            other.execute(
                "INSERT INTO xvb_history (ts, avg_1h, avg_24h, fail_count, donation_fraction, mode) "
                "VALUES (?, 2.0, 0, 0, 0, '')",
                (NOW + 5,),
            )
            other.commit()
            other.close()
            assert [r["avg_1h"] for r in sm.get_xvb_history()] == [1.0, 2.0]
        finally:
            sm.close()

    def test_callers_cannot_corrupt_the_kept_rows(self, state_manager):
        state_manager.add_xvb_history(NOW, avg_1h=1.0)
        state_manager.add_xvb_history(NOW + 1, avg_1h=2.0)
        first = state_manager.get_xvb_history()
        first[0]["avg_1h"] = 999.0
        first[1].clear()
        first.pop()
        second = state_manager.get_xvb_history()
        second[0]["mode"] = "mutated"
        third = state_manager.get_xvb_history()
        assert [r["avg_1h"] for r in third] == [1.0, 2.0]
        assert third[0]["mode"] == ""
        assert third[0] is not second[0]

    def test_windowed_reads_bypass_the_kept_rows(self, state_manager):
        state_manager.add_xvb_history(NOW, avg_1h=1.0)
        state_manager.add_xvb_history(NOW + 100, avg_1h=2.0)
        assert len(state_manager.get_xvb_history()) == 2
        assert [r["avg_1h"] for r in state_manager.get_xvb_history(since=NOW + 50)] == [2.0]
        assert len(state_manager.get_xvb_history()) == 2

    def test_empty_table_result_is_kept_and_dropped_correctly(self, state_manager):
        assert state_manager.get_xvb_history() == []
        seen = self.statements(state_manager)
        assert state_manager.get_xvb_history() == []
        assert self.reads(seen) == []
        state_manager.add_xvb_history(NOW, avg_1h=1.0)
        assert len(state_manager.get_xvb_history()) == 1

    def test_readers_and_a_writer_on_other_threads_stay_consistent(self, state_manager):
        errors = []
        stop = threading.Event()

        def writer():
            try:
                for i in range(150):
                    state_manager.add_xvb_history(NOW + i, avg_1h=float(i))
            except Exception as exc:
                errors.append(exc)
            finally:
                stop.set()

        def reader():
            last = 0
            try:
                while not stop.is_set():
                    rows = state_manager.get_xvb_history()
                    assert len(rows) >= last
                    assert [r["avg_1h"] for r in rows] == [float(i) for i in range(len(rows))]
                    last = len(rows)
            except Exception as exc:
                errors.append(exc)

        threads = [threading.Thread(target=writer)] + [
            threading.Thread(target=reader) for _ in range(3)
        ]
        for t in threads:
            t.start()
        for t in threads:
            t.join(60)
        assert errors == []
        assert [r["avg_1h"] for r in state_manager.get_xvb_history()] == [
            float(i) for i in range(150)
        ]
