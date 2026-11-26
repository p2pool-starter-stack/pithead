import sqlite3
import time
from string import Formatter

import pytest

from mining_dashboard.config.config import HISTORY_RETENTION_SEC
from mining_dashboard.service import event_log_store
from mining_dashboard.service.event_log_store import EVENT_LOG_MAX_ROWS, EVENT_TEXT_TEMPLATES
from mining_dashboard.service.storage_service import StateManager

BASE_TS = 1_780_000_000.0
PAYOUT_SLOTS = {"amount": 1.0, "chain": "XMR"}
PAYOUT_TEXT = "Payout received: 1 XMR reached your wallet"


@pytest.fixture
def fake_clock(monkeypatch):
    clock = {"t": BASE_TS}
    monkeypatch.setattr(event_log_store.time, "time", lambda: clock["t"])
    return clock


def stored_rows(sm):
    return [dict(r) for r in sm._conn.execute("SELECT * FROM event_log ORDER BY id").fetchall()]


class TestForbiddenValuesNeverInStoredText:
    @pytest.mark.parametrize(
        "sample",
        [
            "4AdUndXHHZ6cfufTMvppY6JwXNouMBzSkbLYfpAV5Usx3skxNgYeYTRj5Jz64hAhReYK3oJF7C5PmFYdmbd8s8gBUb5QKgw",
            "pithead7hx4amqji7hr4ryfzba4hq6ks3uq7zokipyqirh7hgt3d2yd.onion",
            "ab" * 32,
            "fe" * 32,
            "correcthorsebattery",
            "ghp_zH8kQ2tVbNwLcX4rYsTf",
            "10.13.37.4",
            "admin",
            "rig-kitchen",
            "ConnectionResetError",
            "wallet.payout_address",
            "https://example.com/onion-pool",
        ],
    )
    def test_forbidden_values_never_reach_the_stored_text(self, state_manager, fake_clock, sample):
        attempts = (
            lambda: state_manager.record_event(
                "payout",
                "monero",
                "Payouts",
                "info",
                "payout_received",
                {"amount": sample, "chain": "XMR"},
            ),
            lambda: state_manager.record_event(
                "payout",
                "monero",
                "Payouts",
                "info",
                "payout_received",
                {"amount": 1.0, "chain": sample},
            ),
            lambda: state_manager.record_event(
                "payout", "monero", "Payouts", "info", sample, dict(PAYOUT_SLOTS)
            ),
            lambda: state_manager.record_event(
                sample, "monero", "Payouts", "info", "payout_received", dict(PAYOUT_SLOTS)
            ),
            lambda: state_manager.record_event(
                "payout", sample, "Payouts", "info", "payout_received", dict(PAYOUT_SLOTS)
            ),
            lambda: state_manager.record_event(
                "payout", "monero", sample, "info", "payout_received", dict(PAYOUT_SLOTS)
            ),
        )
        for attempt in attempts[:3]:
            with pytest.raises(ValueError):
                attempt()
        for attempt in attempts[3:]:
            try:
                attempt()
            except ValueError:
                pass
        texts = {row["text"] for row in stored_rows(state_manager)}
        assert texts <= {PAYOUT_TEXT}
        assert all(sample not in text for text in texts)

    def test_free_text_slot_names_rejected(self, state_manager, fake_clock):
        with pytest.raises(ValueError):
            state_manager.record_event(
                "payout",
                "monero",
                "Payouts",
                "info",
                "payout_received",
                {"amount": 1.0, "chain": "XMR", "detail": "anything"},
            )
        with pytest.raises(ValueError):
            state_manager.record_event(
                "payout", "monero", "Payouts", "info", "payout_received", {"amount": 1.0}
            )
        assert stored_rows(state_manager) == []

    def test_amount_slot_rejects_non_numbers(self, state_manager, fake_clock):
        for bad in ["1.5", True, None, -1.5, float("inf"), float("nan"), "0"]:
            with pytest.raises(ValueError):
                state_manager.record_event(
                    "payout",
                    "monero",
                    "Payouts",
                    "info",
                    "payout_received",
                    {"amount": bad, "chain": "XMR"},
                )
        assert stored_rows(state_manager) == []

    def test_chain_slot_is_an_allowlist(self, state_manager, fake_clock):
        for bad in ["xmr", "XBT", "Monero", "", 1, None]:
            with pytest.raises(ValueError):
                state_manager.record_event(
                    "payout",
                    "monero",
                    "Payouts",
                    "info",
                    "payout_received",
                    {"amount": 1.0, "chain": bad},
                )
        assert stored_rows(state_manager) == []

    def test_unknown_template_rejected(self, state_manager, fake_clock):
        with pytest.raises(ValueError):
            state_manager.record_event(
                "payout", "monero", "Payouts", "info", "My pool paid {amount}", dict(PAYOUT_SLOTS)
            )
        assert stored_rows(state_manager) == []

    @pytest.mark.parametrize(
        ("kind", "subject", "label"),
        [
            ("Bad_Kind", "monero", "Payouts"),
            ("payout", "rig-kitchen.local", "Payouts"),
            ("payout", "monero", "wallet.payout_address"),
            ("-lead", "monero", "Payouts"),
            ("payout", "a" * 33, "Payouts"),
            ("payout", "monero", "404"),
            ("payout", "monero", "l" * 41),
            ("payout", "monero", ""),
        ],
    )
    def test_identifiers_are_bounded_slugs(self, state_manager, fake_clock, kind, subject, label):
        with pytest.raises(ValueError):
            state_manager.record_event(
                kind, subject, label, "info", "payout_received", dict(PAYOUT_SLOTS)
            )
        assert stored_rows(state_manager) == []

    @pytest.mark.parametrize("severity", ["FATAL", "fatal", "warn", "", "debug"])
    def test_severity_is_a_three_value_set(self, state_manager, fake_clock, severity):
        with pytest.raises(ValueError):
            state_manager.record_event(
                "payout", "monero", "Payouts", severity, "payout_received", dict(PAYOUT_SLOTS)
            )
        assert stored_rows(state_manager) == []

    def test_templates_match_their_declared_slots(self):
        for sentence, slot_types in EVENT_TEXT_TEMPLATES.values():
            placeholders = {name for _, name, _, _ in Formatter().parse(sentence) if name}
            assert placeholders == set(slot_types)
            assert set(slot_types.values()) <= set(event_log_store._SLOT_TYPES)


class TestRecordEvent:
    def test_records_row_from_fixed_template(self, state_manager, fake_clock):
        state_manager.record_event(
            "payout",
            "monero_main",
            "Payouts",
            "info",
            "payout_received",
            {"amount": 1.5, "chain": "XTM"},
        )
        assert stored_rows(state_manager) == [
            {
                "id": 1,
                "ts": BASE_TS,
                "end_ts": BASE_TS,
                "count": 1,
                "kind": "payout",
                "subject": "monero_main",
                "label": "Payouts",
                "severity": "info",
                "text": "Payout received: 1.5 XTM reached your wallet",
            }
        ]

    @pytest.mark.parametrize("severity", ["info", "warning", "error"])
    def test_accepts_the_three_severities(self, state_manager, fake_clock, severity):
        state_manager.record_event(
            "sync", f"node_{severity}", "System", severity, "payout_received", dict(PAYOUT_SLOTS)
        )
        rows = stored_rows(state_manager)
        assert len(rows) == 1 and rows[0]["severity"] == severity

    def test_schema_shape(self, state_manager):
        columns = {info[1] for info in state_manager._conn.execute("PRAGMA table_info(event_log)")}
        assert columns == {
            "id",
            "ts",
            "end_ts",
            "count",
            "kind",
            "subject",
            "label",
            "severity",
            "text",
        }
        with pytest.raises(sqlite3.IntegrityError):
            state_manager._conn.execute(
                "INSERT INTO event_log (ts, end_ts, count, kind, subject, label, severity, text) "
                "VALUES (1.0, 1.0, 1, 'k', 's', 'L', 'fatal', 'x')"
            )


class TestRateLimit:
    def test_repeat_within_minute_counts_on_the_row(self, state_manager, fake_clock):
        state_manager.record_event(
            "sync", "node", "System", "error", "payout_received", {"amount": 1.5, "chain": "XMR"}
        )
        fake_clock["t"] = BASE_TS + 20
        state_manager.record_event(
            "sync", "node", "System", "error", "payout_received", {"amount": 9.0, "chain": "XTM"}
        )
        fake_clock["t"] = BASE_TS + 40
        state_manager.record_event(
            "sync", "node", "System", "error", "payout_received", dict(PAYOUT_SLOTS)
        )
        rows = stored_rows(state_manager)
        assert len(rows) == 1
        assert rows[0]["count"] == 3
        assert rows[0]["ts"] == BASE_TS
        assert rows[0]["end_ts"] == BASE_TS + 40
        assert rows[0]["text"] == "Payout received: 1.5 XMR reached your wallet"

    def test_window_is_sixty_seconds(self, state_manager, fake_clock):
        state_manager.record_event(
            "sync", "node", "System", "info", "payout_received", dict(PAYOUT_SLOTS)
        )
        fake_clock["t"] = BASE_TS + 60
        state_manager.record_event(
            "sync", "node", "System", "info", "payout_received", dict(PAYOUT_SLOTS)
        )
        assert len(stored_rows(state_manager)) == 2

    def test_distinct_keys_get_their_own_rows_within_a_minute(self, state_manager, fake_clock):
        for kind, subject in (("sync", "node_a"), ("sync", "node_b"), ("payout", "node_a")):
            state_manager.record_event(
                kind, subject, "System", "warning", "payout_received", dict(PAYOUT_SLOTS)
            )
        assert len(stored_rows(state_manager)) == 3


class TestRetention:
    def test_rows_older_than_thirty_days_are_pruned(self, state_manager, fake_clock):
        state_manager.record_event(
            "sync", "old_node", "System", "error", "payout_received", dict(PAYOUT_SLOTS)
        )
        fake_clock["t"] = BASE_TS + HISTORY_RETENTION_SEC + 1
        state_manager.record_event(
            "sync", "new_node", "System", "error", "payout_received", dict(PAYOUT_SLOTS)
        )
        subjects = {row["subject"] for row in stored_rows(state_manager)}
        assert subjects == {"new_node"}

    def test_20000_rows_in_one_minute_cap_at_5000_and_keep_recent_errors(
        self, state_manager, fake_clock
    ):
        for i in range(20000):
            state_manager.record_event(
                "sync", f"s{i}", "System", "info", "payout_received", dict(PAYOUT_SLOTS)
            )
        state_manager.record_event(
            "sync", "last_error", "System", "error", "payout_received", dict(PAYOUT_SLOTS)
        )
        rows = stored_rows(state_manager)
        assert len(rows) <= EVENT_LOG_MAX_ROWS == 5000
        assert rows[-1]["severity"] == "error"
        subjects = {row["subject"] for row in rows}
        assert "last_error" in subjects
        assert "s0" not in subjects
        assert "s19999" in subjects


class TestChartAndLifecycle:
    def test_add_event_and_chart_events_payload_unchanged(self, state_manager):
        t0 = time.time()
        state_manager.add_event(t0, "loss", "-62%")
        state_manager.add_event(t0 + 100, "recovered", "")
        before = state_manager.get_events()
        for i in range(3):
            state_manager.record_event(
                "sync", f"node{i}", "System", "warning", "payout_received", dict(PAYOUT_SLOTS)
            )
        assert state_manager.get_events() == before
        chart_rows = state_manager._conn.execute("SELECT COUNT(*) FROM events").fetchone()[0]
        assert chart_rows == 2
        assert len(stored_rows(state_manager)) == 3

    def test_event_log_rows_survive_reload(self, tmp_path):
        db = str(tmp_path / "event_log.db")
        sm = StateManager(db_path=db)
        sm.record_event(
            "payout",
            "monero",
            "Payouts",
            "info",
            "payout_received",
            {"amount": 2.5, "chain": "XMR"},
        )
        sm.close()
        sm2 = StateManager(db_path=db)
        try:
            rows = stored_rows(sm2)
            assert len(rows) == 1
            assert rows[0]["text"] == "Payout received: 2.5 XMR reached your wallet"
        finally:
            sm2.close()

    def test_legacy_db_gains_an_empty_event_log_without_copying(self, tmp_path):
        fresh_ts = time.time()
        db = str(tmp_path / "legacy.db")
        conn = sqlite3.connect(db)
        conn.execute("CREATE TABLE events (ts REAL, type TEXT, detail TEXT)")
        conn.execute("INSERT INTO events VALUES (1.0, 'loss', '-50%')")
        conn.execute("INSERT INTO events VALUES (2.0, 'recovered', '')")
        conn.execute("INSERT INTO events VALUES (?, 'loss', 'fresh')", (fresh_ts,))
        conn.execute(
            "CREATE TABLE payouts (chain TEXT, txid TEXT, height INTEGER, ts REAL, "
            "amount_atomic INTEGER)"
        )
        conn.execute("INSERT INTO payouts VALUES ('monero', 'ab12', 100, 1.0, 1500000)")
        conn.commit()
        conn.close()

        sm = StateManager(db_path=db)
        try:
            assert stored_rows(sm) == []
            assert [e["detail"] for e in sm.get_events()] == ["fresh"]
            events_count = sm._conn.execute("SELECT COUNT(*) FROM events").fetchone()[0]
            assert events_count == 3
            payouts_count = sm._conn.execute("SELECT COUNT(*) FROM payouts").fetchone()[0]
            assert payouts_count == 1
        finally:
            sm.close()

    def test_record_event_after_close_is_safe(self, state_manager, fake_clock):
        state_manager.close()
        state_manager.record_event(
            "sync", "node", "System", "info", "payout_received", dict(PAYOUT_SLOTS)
        )
