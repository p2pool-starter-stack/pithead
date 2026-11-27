import sqlite3
import time

from mining_dashboard.service.storage_service import StateManager


class TestWorkerHistoryRateSource:
    def test_rate_and_source_roundtrip(self, state_manager):
        t0 = time.time()
        state_manager.add_worker_history(
            [
                {
                    "ts": t0,
                    "name": "rig1",
                    "h15": 0.0,
                    "accepted": 0,
                    "rejected": 0,
                    "rate": 512.0,
                    "source": "rig",
                },
                {"ts": t0, "name": "rig2", "h15": 100.0, "accepted": 0, "rejected": 0},
            ]
        )
        rows = {r["name"]: r for r in state_manager.get_worker_history()}
        assert rows["rig1"]["rate"] == 512.0
        assert rows["rig1"]["source"] == "rig"
        assert rows["rig2"]["rate"] is None
        assert rows["rig2"]["source"] is None

    def test_recorded_rate_is_preferred_over_raw_h15(self, state_manager):
        state_manager.add_worker_config_version("rig1", "cid1", "applied", {"a": 1}, None, ts=100)
        state_manager.add_worker_history(
            [
                {
                    "ts": 120,
                    "name": "rig1",
                    "h15": 0.0,
                    "accepted": 0,
                    "rejected": 0,
                    "rate": 400.0,
                    "source": "rig",
                }
            ]
        )
        state_manager.add_worker_history(
            [
                {
                    "ts": 140,
                    "name": "rig1",
                    "h15": 800.0,
                    "accepted": 0,
                    "rejected": 0,
                    "rate": 600.0,
                    "source": "rig",
                }
            ]
        )
        rows = state_manager.get_worker_hashrate_by_config("rig1")
        assert rows[0]["avg_h15"] == 500.0

    def test_legacy_h15_only_samples_still_average(self, state_manager):
        state_manager.add_worker_config_version("rig1", "cid1", "applied", {"a": 1}, None, ts=100)
        state_manager.add_worker_history(
            [
                {"ts": 120, "name": "rig1", "h15": 300.0, "accepted": 0, "rejected": 0},
                {"ts": 140, "name": "rig1", "h15": 500.0, "accepted": 0, "rejected": 0},
            ]
        )
        rows = state_manager.get_worker_hashrate_by_config("rig1")
        assert rows[0]["avg_h15"] == 400.0


class TestWorkerHistorySchemaMigration:
    def test_worker_history_rate_and_source_added_on_upgrade(self, tmp_path):
        db = str(tmp_path / "pre_rate.db")
        conn = sqlite3.connect(db)
        conn.execute(
            "CREATE TABLE worker_history "
            "(ts REAL, name TEXT, h15 REAL, accepted INTEGER, rejected INTEGER)"
        )
        conn.execute("INSERT INTO worker_history VALUES (100.0, 'rig1', 1000.0, 1, 0)")
        conn.commit()
        conn.close()

        sm = StateManager(db_path=db)
        try:
            cols = {
                info[1] for info in sm._conn.execute("PRAGMA table_info(worker_history)").fetchall()
            }
            assert {"rate", "source"} <= cols
            legacy = sm.get_worker_history(name="rig1")[0]
            assert legacy["h15"] == 1000.0
            assert legacy["rate"] is None
            assert legacy["source"] is None
            sm.add_worker_history(
                [
                    {
                        "ts": 200.0,
                        "name": "rig1",
                        "h15": 0.0,
                        "accepted": 1,
                        "rejected": 0,
                        "rate": 512.0,
                        "source": "rig",
                    }
                ]
            )
            latest = sm.get_worker_history(name="rig1")[-1]
            assert latest["rate"] == 512.0
            assert latest["source"] == "rig"
        finally:
            sm.close()
