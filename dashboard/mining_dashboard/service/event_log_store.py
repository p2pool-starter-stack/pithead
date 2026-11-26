import math
import re
import sqlite3
import time

from mining_dashboard.config.config import HISTORY_RETENTION_SEC

EVENT_LOG_SEVERITIES = ("info", "warning", "error")
EVENT_LOG_MAX_ROWS = 5000
EVENT_LOG_RATE_WINDOW_SEC = 60.0

EVENT_TEXT_TEMPLATES = {
    "payout_received": (
        "Payout received: {amount} {chain} reached your wallet",
        {"amount": "amount", "chain": "chain"},
    ),
}

_KIND_SUBJECT_PATTERN = re.compile(r"\A[a-z0-9][a-z0-9_-]{0,31}\Z")
_LABEL_PATTERN = re.compile(r"\A[A-Za-z][A-Za-z0-9 _-]{0,39}\Z")

_CHAIN_ALLOWLIST = frozenset({"XMR", "XTM"})


def _slot_amount(value: object) -> str:
    if isinstance(value, bool) or not isinstance(value, (int, float)):
        raise ValueError("event log amount slot takes a number, not free text")
    try:
        amount = float(value)
    except OverflowError:
        raise ValueError("event log amount slot takes a finite non-negative number") from None
    if not math.isfinite(amount) or amount < 0:
        raise ValueError("event log amount slot takes a finite non-negative number")
    return f"{amount:g}"


def _slot_chain(value: object) -> str:
    if not isinstance(value, str) or value not in _CHAIN_ALLOWLIST:
        raise ValueError("event log chain slot takes an allow-listed chain ticker")
    return value


_SLOT_TYPES = {"amount": _slot_amount, "chain": _slot_chain}


def _render_event_text(text_template: str, slots: dict[str, object]) -> str:
    if not isinstance(text_template, str):
        raise ValueError("event log text_template must name a fixed sentence template")
    template = EVENT_TEXT_TEMPLATES.get(text_template)
    if template is None:
        raise ValueError("event log text_template must name a fixed sentence template")
    sentence, slot_types = template
    if not isinstance(slots, dict):
        raise ValueError("event log slots must be a dict of template placeholders")
    if set(slots) != set(slot_types):
        raise ValueError("event log slots must match the template's placeholders exactly")
    rendered = {name: _SLOT_TYPES[slot_type](slots[name]) for name, slot_type in slot_types.items()}
    return sentence.format(**rendered)


class EventLogStoreMixin:
    def record_event(
        self,
        kind: str,
        subject: str,
        label: str,
        severity: str,
        text_template: str,
        slots: dict[str, object],
    ) -> None:
        if not isinstance(kind, str) or not _KIND_SUBJECT_PATTERN.match(kind):
            raise ValueError("event log kind must be a lowercase slug of at most 32 characters")
        if not isinstance(subject, str) or not _KIND_SUBJECT_PATTERN.match(subject):
            raise ValueError("event log subject must be a lowercase slug of at most 32 characters")
        if not isinstance(label, str) or not _LABEL_PATTERN.match(label):
            raise ValueError(
                "event log label must start with a letter and hold letters, digits, "
                "spaces, underscores or hyphens, at most 40 characters"
            )
        if severity not in EVENT_LOG_SEVERITIES:
            raise ValueError("event log severity must be info, warning or error")
        text = _render_event_text(text_template, slots)
        now = time.time()
        try:
            with self._db_lock:
                if not self._conn:
                    return
                with self._conn:
                    repeat = self._conn.execute(
                        "SELECT id FROM event_log WHERE kind = ? AND subject = ? AND ts > ? "
                        "ORDER BY id DESC LIMIT 1",
                        (kind, subject, now - EVENT_LOG_RATE_WINDOW_SEC),
                    ).fetchone()
                    if repeat is not None:
                        self._conn.execute(
                            "UPDATE event_log SET count = count + 1, end_ts = ? WHERE id = ?",
                            (now, repeat[0]),
                        )
                    else:
                        self._conn.execute(
                            "INSERT INTO event_log "
                            "(ts, end_ts, count, kind, subject, label, severity, text) "
                            "VALUES (?, ?, 1, ?, ?, ?, ?, ?)",
                            (now, now, kind, subject, label, severity, text),
                        )
                    self._conn.execute(
                        "DELETE FROM event_log WHERE ts < ?",
                        (now - HISTORY_RETENTION_SEC,),
                    )
                    self._conn.execute(
                        "DELETE FROM event_log WHERE id <= (SELECT MAX(id) - ? FROM event_log)",
                        (EVENT_LOG_MAX_ROWS,),
                    )
        except sqlite3.Error as e:
            self._db_error("Event Log Write Error", e)
