import sqlite3

from mining_dashboard.service.storage_service import StateManager

ROWS = [(float(i), f"rig{i % 3}", float(i), i, 0) for i in range(300)]


def _legacy_db(path):
    sm = StateManager(db_path=str(path))
    sm._conn.execute("DROP INDEX IF EXISTS idx_worker_history_name_ts")
    sm._conn.executemany("INSERT INTO worker_history VALUES (?, ?, ?, ?, ?)", ROWS)
    sm._conn.commit()
    sm.close()


def test_startup_adds_the_name_index_and_the_worker_detail_query_uses_it(tmp_path):
    path = tmp_path / "state.db"
    _legacy_db(path)
    raw = sqlite3.connect(path)
    names = {r[1] for r in raw.execute("PRAGMA index_list(worker_history)")}
    raw.close()
    assert "idx_worker_history_name_ts" not in names

    sm = StateManager(db_path=str(path))
    try:
        statements = []
        sm._conn.set_trace_callback(statements.append)
        got = sm.get_worker_history(since=10.0, name="rig1")
        sm._conn.set_trace_callback(None)
        query = next(s for s in statements if "worker_history" in s)
        plan = " ".join(r[3] for r in sm._conn.execute("EXPLAIN QUERY PLAN " + query))
        assert "idx_worker_history_name_ts" in plan
        want = [
            {"ts": r[0], "name": r[1], "h15": r[2], "accepted": r[3], "rejected": r[4]}
            for r in ROWS
            if r[0] >= 10.0 and r[1] == "rig1"
        ]
        assert got == want and got
    finally:
        sm.close()
