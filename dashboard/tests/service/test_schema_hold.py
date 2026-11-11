import sqlite3

from mining_dashboard.service.storage_service import StateManager


class TestSchemaMigrationHold:
    _LEGACY_DDL = (
        "CREATE TABLE payouts "
        "(chain TEXT, txid TEXT, height INTEGER, ts REAL, amount_atomic INTEGER, "
        "PRIMARY KEY (chain, txid))"
    )

    def _seed_legacy_db(self, db):
        conn = sqlite3.connect(db)
        conn.execute(self._LEGACY_DDL)
        conn.execute(
            "INSERT INTO payouts (chain, txid, height, ts, amount_atomic) "
            "VALUES ('monero', 'tx-old', 5, 5.0, 1000)"
        )
        conn.commit()
        conn.close()

    def _payout_columns(self, db):
        conn = sqlite3.connect(db)
        try:
            return {info[1] for info in conn.execute("PRAGMA table_info(payouts)")}
        finally:
            conn.close()

    def _hold(self, tmp_path):
        marker = tmp_path / ".os-schema-held"
        marker.write_text("")
        return marker

    def test_hold_defers_the_payout_identity_rebuild(self, tmp_path):
        db = str(tmp_path / "mining.db")
        self._seed_legacy_db(db)
        self._hold(tmp_path)
        sm = StateManager(db_path=db)
        try:
            assert sm._payouts_have_wallet is False
            assert "wallet_id" not in self._payout_columns(db)
        finally:
            sm.close()

    def test_hold_releases_the_migration_on_the_next_open(self, tmp_path):
        db = str(tmp_path / "mining.db")
        self._seed_legacy_db(db)
        marker = self._hold(tmp_path)
        StateManager(db_path=db).close()
        marker.unlink()
        sm = StateManager(db_path=db)
        try:
            assert sm._payouts_have_wallet is True
            cols = self._payout_columns(db)
            assert "wallet_id" in cols
            rows = sm.get_payouts("monero", "unknown")
            assert [r["txid"] for r in rows] == ["tx-old"]
        finally:
            sm.close()

    def test_hold_creates_fresh_databases_in_the_previous_shape(self, tmp_path):
        db = str(tmp_path / "mining.db")
        self._hold(tmp_path)
        sm = StateManager(db_path=db)
        try:
            assert sm._payouts_have_wallet is False
            assert "wallet_id" not in self._payout_columns(db)
        finally:
            sm.close()

    def test_payouts_keep_recording_on_the_previous_shape(self, tmp_path):
        db = str(tmp_path / "mining.db")
        self._seed_legacy_db(db)
        self._hold(tmp_path)
        sm = StateManager(db_path=db)
        try:
            new = sm.add_payouts(
                "monero",
                "wallet-alpha",
                [{"txid": "tx-new", "height": 9, "ts": 9.0, "amount_atomic": 2000}],
            )
            assert [r["txid"] for r in new] == ["tx-new"]
            again = sm.add_payouts(
                "monero",
                "wallet-beta",
                [{"txid": "tx-new", "height": 9, "ts": 9.0, "amount_atomic": 2000}],
            )
            assert again == []
            rows = sm.get_payouts("monero", "wallet-beta")
            assert [r["txid"] for r in rows] == ["tx-new", "tx-old"]
            assert sm.get_payout_max_height("monero", "wallet-beta") == 9
        finally:
            sm.close()
        conn = sqlite3.connect(db)
        try:
            stored = conn.execute("SELECT chain, txid, amount_atomic FROM payouts").fetchall()
        finally:
            conn.close()
        assert ("monero", "tx-new", 2000) in stored
