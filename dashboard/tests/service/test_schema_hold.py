import os
import shutil
import sqlite3
import subprocess
from pathlib import Path

import pytest

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


_BOOT = Path(__file__).resolve().parents[3] / "os" / "overlay" / "pithead-boot"


@pytest.mark.skipif(not _BOOT.is_file(), reason="needs the repo checkout's os/overlay/pithead-boot")
class TestSchemaHoldAcrossAFailedUpdate:
    _PREVIOUS_RELEASE_INSERT = (
        "INSERT OR IGNORE INTO payouts "
        "(chain, txid, height, ts, amount_atomic) VALUES (?, ?, ?, ?, ?)"
    )

    def _arm_from_an_uncommitted_candidate(self, tmp_path, data_dir):
        run = tmp_path / "run"
        bin_dir = tmp_path / "bin"
        run.mkdir()
        bin_dir.mkdir()
        (run / ".env").write_text(f"DASHBOARD_DATA_DIR={data_dir}\n")
        cmdline = tmp_path / "cmdline"
        cmdline.write_text("rootwait rauc.slot=B\n")
        rauc = bin_dir / "rauc"
        rauc.write_text(
            "#!/usr/bin/env bash\n"
            'echo \'{"slots":{"rootfs":{"B":{"state":"booted",'
            '"bootname":"B","boot_status":"bad"}}}}\'\n'
        )
        rauc.chmod(0o755)
        armed = subprocess.run(  # noqa: S603
            [shutil.which("bash"), "-c", 'source "$1" && schema_hold_arm', "arm", str(_BOOT)],
            cwd=run,
            env={
                **os.environ,
                "PATH": f"{bin_dir}{os.pathsep}{os.environ['PATH']}",
                "PITHEAD_CMDLINE": str(cmdline),
            },
            capture_output=True,
            text=True,
            check=False,
        )
        assert armed.returncode == 0, armed.stderr
        assert "dashboard schema hold armed" in armed.stdout

    def test_previous_release_records_payouts_after_the_candidate_falls_back(self, tmp_path):
        data_dir = tmp_path / "dashboard"
        data_dir.mkdir()
        db = str(data_dir / "mining_data.db")
        TestSchemaMigrationHold()._seed_legacy_db(db)
        self._arm_from_an_uncommitted_candidate(tmp_path, data_dir)
        StateManager(db_path=db).close()
        conn = sqlite3.connect(db)
        try:
            with conn:
                conn.execute(
                    self._PREVIOUS_RELEASE_INSERT, ("monero", "tx-fallback", 12, 12.0, 3000)
                )
            stored = conn.execute(
                "SELECT chain, txid, height, ts, amount_atomic FROM payouts "
                "WHERE chain = ? ORDER BY ts DESC",
                ("monero",),
            ).fetchall()
        finally:
            conn.close()
        assert stored[0] == ("monero", "tx-fallback", 12, 12.0, 3000)
