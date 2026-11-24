import sqlite3
from typing import Any


class PayoutAlertRetryMixin:
    def get_payout_alert_retries(self, chain: str, wallet_id: str | None) -> list[dict[str, Any]]:
        if not wallet_id:
            return []
        try:
            with self._db_lock:
                if not self._conn:
                    return []
                with self._conn:
                    self._conn.execute(
                        "DELETE FROM payout_alert_retry WHERE chain = ? AND wallet_id != ?",
                        (chain, wallet_id),
                    )
                cursor = self._conn.execute(
                    "SELECT txid, amount_atomic, first_ts FROM payout_alert_retry "
                    "WHERE chain = ? AND wallet_id = ? ORDER BY first_ts",
                    (chain, wallet_id),
                )
                return [dict(row) for row in cursor.fetchall()]
        except sqlite3.Error as e:
            self.logger.error(f"Payout Alert Retry Read Error: {e}")
            return []

    def clear_payout_alert_retry(self, chain: str, wallet_id: str | None, txid: str) -> None:
        try:
            with self._db_lock:
                if not self._conn:
                    return
                with self._conn:
                    self._conn.execute(
                        "DELETE FROM payout_alert_retry WHERE chain = ? AND wallet_id = ? "
                        "AND txid = ?",
                        (chain, wallet_id, txid),
                    )
        except sqlite3.Error as e:
            self._db_error("Payout Alert Retry Clear Error", e)
