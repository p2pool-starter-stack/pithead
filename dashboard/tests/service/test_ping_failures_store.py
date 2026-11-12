from mining_dashboard.service.storage_service import StateManager


def _sm():
    return StateManager(db_path=":memory:")


class TestPingFailuresStore:
    def test_empty_store_reads_empty(self):
        sm = _sm()
        try:
            assert sm.get_ping_failures() == []
        finally:
            sm.close()

    def test_records_newest_first(self):
        sm = _sm()
        try:
            sm.record_ping_failure(100.0, "connect", "ConnectionError")
            sm.record_ping_failure(200.0, "http_status", "HTTP 404")
            rows = sm.get_ping_failures()
            assert [r["reason"] for r in rows] == ["http_status", "connect"]
            assert rows[0]["ts"] == 200.0
            assert rows[1]["detail"] == "ConnectionError"
        finally:
            sm.close()

    def test_ring_keeps_only_the_newest_rows(self):
        sm = _sm()
        try:
            for i in range(sm.PING_FAILURES_KEPT + 25):
                sm.record_ping_failure(float(i), "connect", f"row {i}")
            rows = sm.get_ping_failures(limit=1000)
            assert len(rows) == sm.PING_FAILURES_KEPT
            assert rows[0]["detail"] == f"row {sm.PING_FAILURES_KEPT + 24}"
        finally:
            sm.close()

    def test_limit_bounds_the_read(self):
        sm = _sm()
        try:
            for i in range(5):
                sm.record_ping_failure(float(i), "dns", "")
            assert len(sm.get_ping_failures(limit=2)) == 2
        finally:
            sm.close()

    def test_detail_is_truncated_so_nothing_long_hides_in_the_column(self):
        sm = _sm()
        try:
            sm.record_ping_failure(1.0, "connect", "x" * 5000)
            assert len(sm.get_ping_failures()[0]["detail"]) == 200
        finally:
            sm.close()

    def test_recorder_survives_a_closed_connection(self):
        sm = _sm()
        sm.close()
        sm.record_ping_failure(1.0, "connect", "after close")
        assert sm.get_ping_failures() == []

    def test_a_broken_store_costs_a_row_and_an_empty_read(self):
        sm = _sm()
        try:
            sm._conn.execute("DROP TABLE ping_failures")
            sm._conn.commit()
            sm.record_ping_failure(1.0, "connect", "boom")
            assert sm.get_ping_failures() == []
        finally:
            sm.close()
