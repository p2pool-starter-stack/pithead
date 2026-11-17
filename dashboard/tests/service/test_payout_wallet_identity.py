import asyncio
import sqlite3
from unittest.mock import AsyncMock

import pytest

from mining_dashboard.config import config
from mining_dashboard.service import payout_sync

_WALLET_A = "wallet-alpha"
_WALLET_B = "wallet-beta"
_SHARED_TXID = "shared-receipt"


def _row(height, amount):
    return {
        "txid": _SHARED_TXID,
        "height": height,
        "ts": float(height),
        "amount_atomic": amount,
    }


class _MoneroScan:
    def __init__(self):
        self.calls = []

    def scan(self, min_height):
        wallet = config.MONERO_WALLET_ADDRESS
        self.calls.append((wallet, min_height))
        row = _row(100, 1000) if wallet == _WALLET_A else _row(20, 2000)
        return ([row] if row["height"] >= min_height else [], True)


class _TariScan:
    def __init__(self):
        self.calls = []

    async def scan(self, min_height):
        wallet = config.TARI_WALLET_ADDRESS
        self.calls.append((wallet, min_height))
        row = _row(100, 1000) if wallet == _WALLET_A else _row(20, 2000)
        return ([row] if row["height"] >= min_height else [], True)


class _SwitchingMoneroScan:
    def scan(self, min_height):
        config.MONERO_WALLET_ADDRESS = _WALLET_B
        return ([_row(8, 800)], True)


class _SwitchingTariScan:
    async def scan(self, min_height):
        config.TARI_WALLET_ADDRESS = _WALLET_B
        return ([_row(8, 800)], True)


class _FailingMigrationConnection:
    def __init__(self, connection):
        self.connection = connection

    def execute(self, sql, parameters=()):
        if sql.startswith("INSERT INTO payouts "):
            raise sqlite3.OperationalError("forced migration failure")
        return self.connection.execute(sql, parameters)

    def __getattr__(self, name):
        return getattr(self.connection, name)


def _set_wallet(monkeypatch, chain, wallet):
    attr = "TARI_WALLET_ADDRESS" if chain == "tari" else "MONERO_WALLET_ADDRESS"
    monkeypatch.setattr(config, attr, wallet)


@pytest.mark.parametrize("chain", ["monero", "tari"])
def test_wallet_switch_keeps_history_cursor_and_alerts_per_identity(tmp_path, monkeypatch, chain):
    from mining_dashboard.service.storage_service import StateManager

    db_path = tmp_path / f"{chain}.db"
    store = StateManager(db_path=str(db_path))
    scanner = _MoneroScan() if chain == "monero" else _TariScan()
    alert = AsyncMock()
    sync = payout_sync.sync_monero if chain == "monero" else payout_sync.sync_tari
    try:
        _set_wallet(monkeypatch, chain, _WALLET_A)
        assert asyncio.run(sync(store, scanner, alert)) is True

        _set_wallet(monkeypatch, chain, _WALLET_B)
        assert asyncio.run(sync(store, scanner, alert)) is True

        _set_wallet(monkeypatch, chain, _WALLET_A)
        assert asyncio.run(sync(store, scanner, alert)) is True

        assert scanner.calls == [(_WALLET_A, 0), (_WALLET_B, 0), (_WALLET_A, 100)]
        from mining_dashboard.service import payout_identity

        wallet_a = payout_identity.configured_wallet_id(chain)
        _set_wallet(monkeypatch, chain, _WALLET_B)
        wallet_b = payout_identity.configured_wallet_id(chain)
        assert wallet_a and wallet_b and wallet_b != wallet_a
        assert store.get_payout_max_height(chain, wallet_a) == 100
        assert store.get_payout_max_height(chain, wallet_b) == 20
        assert [row["amount_atomic"] for row in store.get_payouts(chain, wallet_a)] == [1000]
        assert [row["amount_atomic"] for row in store.get_payouts(chain, wallet_b)] == [2000]
        assert alert.payout_confirmed_alert.await_count == 2
    finally:
        store.close()

    reopened = StateManager(db_path=str(db_path))
    try:
        assert reopened.get_payout_max_height(chain, wallet_a) == 100
        assert reopened.get_payout_max_height(chain, wallet_b) == 20
        assert reopened.get_payouts(chain, wallet_a)[0]["amount_atomic"] == 1000
        assert reopened.get_payouts(chain, wallet_b)[0]["amount_atomic"] == 2000
    finally:
        reopened.close()


@pytest.mark.parametrize("chain", ["monero", "tari"])
def test_missing_wallet_identity_skips_scan_and_storage(monkeypatch, chain):
    from mining_dashboard.service.storage_service import StateManager

    attr = "MONERO_WALLET_ADDRESS" if chain == "monero" else "TARI_WALLET_ADDRESS"
    monkeypatch.setattr(config, attr, "")
    store = StateManager(db_path=":memory:")
    scanner = _MoneroScan() if chain == "monero" else _TariScan()
    alert = AsyncMock()
    sync = payout_sync.sync_monero if chain == "monero" else payout_sync.sync_tari
    try:
        assert asyncio.run(sync(store, scanner, alert)) is False
        assert scanner.calls == []
        assert store.add_payouts(chain, None, [_row(1, 1)]) == []
        assert store.get_payouts(chain, None) == []
        assert store.get_payout_max_height(chain, None) == 0
        alert.payout_confirmed_alert.assert_not_awaited()
    finally:
        store.close()


@pytest.mark.parametrize("chain", ["monero", "tari"])
def test_sync_keeps_identity_captured_before_wallet_scan(monkeypatch, chain):
    from mining_dashboard.service.storage_service import StateManager

    _set_wallet(monkeypatch, chain, _WALLET_A)
    store = StateManager(db_path=":memory:")
    scanner = _SwitchingMoneroScan() if chain == "monero" else _SwitchingTariScan()
    alert = AsyncMock()
    sync = payout_sync.sync_monero if chain == "monero" else payout_sync.sync_tari
    try:
        assert asyncio.run(sync(store, scanner, alert)) is True
        from mining_dashboard.service import payout_identity

        wallet_b = payout_identity.configured_wallet_id(chain)
        _set_wallet(monkeypatch, chain, _WALLET_A)
        wallet_a = payout_identity.configured_wallet_id(chain)
        assert len(store.get_payouts(chain, wallet_a)) == 1
        assert store.get_payouts(chain, wallet_b) == []
    finally:
        store.close()


def test_wallet_identity_separates_chains_and_canonicalizes_tari(monkeypatch):
    from mining_dashboard.service import payout_identity

    monkeypatch.setattr(payout_identity, "decode_address", lambda value: b"canonical-tari")
    monkeypatch.setattr(payout_identity, "address_key", lambda raw: raw)
    _set_wallet(monkeypatch, "tari", _WALLET_A)
    tari_a = payout_identity.configured_wallet_id("tari")
    _set_wallet(monkeypatch, "tari", _WALLET_B)
    assert payout_identity.configured_wallet_id("tari") == tari_a
    _set_wallet(monkeypatch, "monero", _WALLET_A)
    assert payout_identity.configured_wallet_id("monero") != tari_a


@pytest.mark.parametrize("chain", ["monero", "tari"])
def test_legacy_payouts_migrate_to_unknown_without_claiming_current_wallet(
    tmp_path, monkeypatch, chain
):
    from mining_dashboard.service.storage_service import StateManager

    db_path = tmp_path / "legacy.db"
    connection = sqlite3.connect(db_path)
    connection.execute(
        "CREATE TABLE payouts (chain TEXT, txid TEXT, height INTEGER, ts REAL, "
        "amount_atomic INTEGER, PRIMARY KEY (chain, txid))"
    )
    connection.execute(
        "INSERT INTO payouts (chain, txid, height, ts, amount_atomic) VALUES (?, ?, ?, ?, ?)",
        (chain, _SHARED_TXID, 77, 77.0, 7000),
    )
    connection.commit()
    connection.close()

    _set_wallet(monkeypatch, chain, _WALLET_A)
    from mining_dashboard.service import payout_identity

    wallet_id = payout_identity.configured_wallet_id(chain)
    store = StateManager(db_path=str(db_path))
    try:
        assert store.get_payouts(chain, wallet_id) == []
        unknown = store.get_payouts(chain, "unknown")
        assert [(row["txid"], row["amount_atomic"]) for row in unknown] == [(_SHARED_TXID, 7000)]
        inserted = store.add_payouts(chain, wallet_id, [_row(77, 7100)])
        assert inserted == [_row(77, 7100)]
        pk = {
            row[1]: row[5]
            for row in store._conn.execute("PRAGMA table_info(payouts)").fetchall()
            if row[5]
        }
        assert pk == {"chain": 1, "wallet_id": 2, "txid": 3}
    finally:
        store.close()

    reopened = StateManager(db_path=str(db_path))
    try:
        assert len(reopened.get_payouts(chain, "unknown")) == 1
        assert len(reopened.get_payouts(chain, wallet_id)) == 1
        assert reopened.add_payouts(chain, wallet_id, [_row(77, 7100)]) == []
    finally:
        reopened.close()


def test_failed_legacy_migration_rolls_back_without_losing_receipts():
    from mining_dashboard.service.storage_service import StateManager

    store = StateManager(db_path=":memory:")
    connection = store._conn
    try:
        connection.execute("DROP TABLE payouts")
        connection.execute(
            "CREATE TABLE payouts (chain TEXT, txid TEXT, height INTEGER, ts REAL, "
            "amount_atomic INTEGER, PRIMARY KEY (chain, txid))"
        )
        connection.execute(
            "INSERT INTO payouts (chain, txid, height, ts, amount_atomic) VALUES (?, ?, ?, ?, ?)",
            ("monero", _SHARED_TXID, 9, 9.0, 9000),
        )
        connection.commit()
        store._conn = _FailingMigrationConnection(connection)

        with pytest.raises(sqlite3.OperationalError, match="forced migration failure"):
            store._migrate_payout_identity(store._conn.cursor())

        columns = {row[1] for row in connection.execute("PRAGMA table_info(payouts)")}
        rows = connection.execute(
            "SELECT chain, txid, height, amount_atomic FROM payouts"
        ).fetchall()
        tables = {
            row[0]
            for row in connection.execute(
                "SELECT name FROM sqlite_master WHERE type = 'table' AND name LIKE 'payouts%'"
            )
        }
        assert "wallet_id" not in columns
        assert [tuple(row) for row in rows] == [("monero", _SHARED_TXID, 9, 9000)]
        assert tables == {"payouts"}
    finally:
        store._conn = connection
        store.close()
