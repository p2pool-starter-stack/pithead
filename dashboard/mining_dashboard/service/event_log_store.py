import random
import sqlite3
import time
from typing import Any


class EventLogStoreMixin:

    def record_event(
        self,
        kind: str,
        subject: str,
        label: str,
        severity: str,
        text_template: str,
        slots: dict,
    ) -> None:
        text = text_template.format(**slots) if text_template and slots else text_template or ""
        ts = time.time()
        opened = False
        closed = False
        is_episode_repeat = False
        try:
            with self._db_lock:
                if not self._conn:
                    return
                with self._conn:
                    if severity == "error":
                        row = self._conn.execute(
                            "SELECT id, count FROM event_log "
                            "WHERE kind = ? AND subject = ? AND end_ts IS NULL "
                            "ORDER BY ts DESC LIMIT 1",
                            (kind, subject),
                        ).fetchone()
                        if row:
                            self._conn.execute(
                                "UPDATE event_log SET count = count + 1, ts = ? "
                                "WHERE id = ? AND end_ts IS NULL",
                                (ts, row[0]),
                            )
                            is_episode_repeat = True
                    else:
                        row = self._conn.execute(
                            "SELECT id FROM event_log "
                            "WHERE kind = ? AND subject = ? AND end_ts IS NULL "
                            "ORDER BY ts DESC LIMIT 1",
                            (kind, subject),
                        ).fetchone()
                        if row:
                            self._conn.execute(
                                "UPDATE event_log SET end_ts = ? WHERE id = ? AND end_ts IS NULL",
                                (ts, row[0]),
                            )
                            closed = True
                    if not is_episode_repeat:
                        count_row = self._conn.execute(
                            "SELECT COUNT(*) FROM event_log "
                            "WHERE kind = ? AND subject = ? AND ts > ?",
                            (kind, subject, ts - 60),
                        ).fetchone()
                        if count_row[0] == 0:
                            self._conn.execute(
                                "INSERT INTO event_log (ts, end_ts, count, kind, subject, "
                                "label, severity, text) VALUES (?, NULL, 1, ?, ?, ?, ?, ?)",
                                (ts, kind, subject, label, severity, text),
                            )
                            opened = True
                        elif severity == "error":
                            self._conn.execute(
                                "INSERT INTO event_log (ts, end_ts, count, kind, subject, "
                                "label, severity, text) VALUES (?, NULL, 1, ?, ?, ?, ?, ?)",
                                (ts, kind, subject, label, severity, text),
                            )
                            opened = True
                    if random.random() < 0.05:  # noqa: S311 — pruning sampler
                        self._conn.execute(
                            "DELETE FROM event_log WHERE ts < ? AND rowid NOT IN "
                            "(SELECT rowid FROM event_log ORDER BY rowid DESC LIMIT 5000)",
                            (ts - 30 * 24 * 3600,),
                        )
        except sqlite3.Error as e:
            self._db_error("Event Log Insert Error", e)
        with self._lock:
            self.state.setdefault("event_log", []).append({
                "kind": kind, "subject": subject, "label": label,
                "severity": severity, "text": text,
                "opened": opened, "closed": closed,
                "is_episode_repeat": is_episode_repeat,
            })
            cutoff = time.time() - 30 * 24 * 3600
            self.state["event_log"] = [
                e for e in self.state["event_log"] if e.get("_ts", ts) >= cutoff
            ]

    def get_open_episodes(self) -> list[dict[str, Any]]:
        try:
            with self._db_lock:
                if not self._conn:
                    return []
                cursor = self._conn.cursor()
                cursor.execute(
                    "SELECT id, ts, end_ts, count, kind, subject, label, severity, text "
                    "FROM event_log WHERE end_ts IS NULL AND severity = 'error' "
                    "ORDER BY ts DESC"
                )
                return [dict(row) for row in cursor.fetchall()]
        except sqlite3.Error as e:
            self.logger.error(f"Open Episodes Read Error: {e}")
            return []