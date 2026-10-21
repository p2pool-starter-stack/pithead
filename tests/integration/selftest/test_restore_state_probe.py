import importlib.util
import io
import json
import os
import sqlite3
import subprocess
import tarfile
import tempfile
import unittest
from contextlib import redirect_stderr
from pathlib import Path
from unittest.mock import patch

SPEC = importlib.util.spec_from_file_location(
    "restore_probe", Path(__file__).resolve().parents[1] / "lib/restore-state-probe.py"
)
PROBE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(PROBE)


class RestoreStateProbeTests(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.addCleanup(self.directory.cleanup)
        self.root = Path(self.directory.name).resolve()
        self.prior = Path.cwd()
        os.chdir(self.root)
        self.addCleanup(os.chdir, self.prior)
        (self.root / "tor").mkdir()
        (self.root / "dashboard").mkdir()
        (self.root / "tor/key").write_bytes(os.urandom(8192))
        (self.root / "tor/state").write_bytes(b"fixture circuit history")
        (self.root / "config.json").write_text('{"config_version":"2.0.0"}')
        (self.root / "VERSION").write_text("2.1.0-rc1\n")
        (self.root / ".env").write_text(
            f"TOR_DATA_DIR={self.root}/tor\nDASHBOARD_DATA_DIR={self.root}/dashboard\n"
        )
        (self.root / "Caddyfile").write_text("fixture route\n")
        self.db = self.root / "dashboard/mining_data.db"
        with sqlite3.connect(self.db) as conn:
            conn.executescript(
                "CREATE TABLE parent(id INTEGER PRIMARY KEY);"
                "CREATE TABLE child(id INTEGER REFERENCES parent(id));"
                'CREATE TABLE "odd table"(value TEXT);'
                "INSERT INTO parent VALUES(1); INSERT INTO child VALUES(1);"
                'INSERT INTO "odd table" VALUES("fixture");'
            )
        self.archive = self.root / "backup.tar.gz"
        with tarfile.open(self.archive, "w:gz") as archive:
            for name in ("config.json", ".env", "Caddyfile", "tor", "dashboard"):
                archive.add(self.root / name, arcname=str(self.root / name).lstrip("/"))
        (self.root / "tor/state").unlink()

    def verify(self):
        with tarfile.open(self.archive) as archive:
            PROBE.verify(archive, self.root)

    def snapshot(self):
        with tarfile.open(self.archive) as archive:
            return PROBE.snapshot(archive)

    def test_complete_restore_passes(self):
        self.verify()
        self.assertEqual(PROBE.database_counts(self.db), {"parent": 1, "child": 1, "odd table": 1})

    def test_restored_tor_circuit_state_is_rejected(self):
        state = self.root / "tor/state"
        for symlink in (False, True):
            with self.subTest(symlink=symlink):
                if symlink:
                    state.symlink_to("missing-circuit-history")
                else:
                    state.write_bytes(b"fixture circuit history")
                with self.assertRaisesRegex(ValueError, "Tor circuit state"):
                    self.verify()
                state.unlink()

    def test_refusal_snapshot_preserves_tor_circuit_state(self):
        state = self.root / "tor/state"
        state.write_bytes(b"fixture circuit history")
        before = self.snapshot()
        state.write_bytes(b"changed circuit history")
        self.assertNotEqual(before, self.snapshot())
        state.unlink()
        self.assertNotEqual(before, self.snapshot())

    def test_configless_snapshot_covers_absence_and_every_file(self):
        for name in ("config.json", ".env", "Caddyfile"):
            (self.root / name).unlink()
        before = self.snapshot()
        self.assertEqual(before, self.snapshot())
        for name in ("config.json", ".env", "Caddyfile", "tor/new", "dashboard/mining_data.db-wal"):
            target = self.root / name
            with self.subTest(name=name):
                target.write_bytes(b"unexpected")
                self.assertNotEqual(before, self.snapshot())
                target.unlink()
        (self.root / "tor/key").write_bytes(b"changed")
        self.assertNotEqual(before, self.snapshot())

    def test_changed_or_missing_archive_file_fails(self):
        for name in ("config.json", ".env", "Caddyfile", "tor/key"):
            target = self.root / name
            original = target.read_bytes()
            with self.subTest(name=name):
                target.write_bytes(b"changed")
                with self.assertRaises(ValueError):
                    self.verify()
                target.unlink()
                with self.assertRaises(ValueError):
                    self.verify()
                target.write_bytes(original)

    def test_lost_rows_fail_exact_count_compare(self):
        expected = PROBE.database_counts(self.db)
        with sqlite3.connect(self.db) as conn:
            conn.execute('DELETE FROM "odd table"')
        self.assertNotEqual(expected, PROBE.database_counts(self.db))
        with self.assertRaisesRegex(ValueError, "table counts"):
            self.verify()

    def test_file_failure_diagnostics_expose_only_fixed_categories(self):
        for name, category in (
            ("config.json", "config.json"),
            (".env", ".env"),
            ("Caddyfile", "Caddyfile"),
            ("tor/key", "Tor"),
        ):
            target = self.root / name
            original = target.read_bytes()
            with self.subTest(name=name):
                target.write_bytes(b"private fixture value")
                output = io.StringIO()
                with patch.object(PROBE, "main", self.verify), redirect_stderr(output):
                    self.assertEqual(PROBE.run(), 1)
                self.assertIn(f"restored file differs from archive: {category}", output.getvalue())
                self.assertNotIn(str(self.root), output.getvalue())
                self.assertNotIn("private fixture value", output.getvalue())
                target.write_bytes(original)

    def test_unexpected_failure_reports_type_without_exception_values(self):
        output = io.StringIO()
        error = OSError(f"private fixture value at {self.root}")
        with patch.object(PROBE, "main", side_effect=error), redirect_stderr(output):
            self.assertEqual(PROBE.run(), 1)
        self.assertEqual(output.getvalue(), "restore state probe failed: OSError\n")

    def test_missing_table_fails(self):
        with sqlite3.connect(self.db) as conn:
            conn.execute('DROP TABLE "odd table"')
        with self.assertRaises(ValueError):
            self.verify()

    def test_foreign_key_violation_fails(self):
        with sqlite3.connect(self.db) as conn:
            conn.execute("INSERT INTO child VALUES(99)")
        with self.assertRaisesRegex(ValueError, "foreign key"):
            PROBE.database_counts(self.db)

    def test_corrupt_database_fails(self):
        self.db.write_bytes(b"not sqlite")
        with self.assertRaises(sqlite3.DatabaseError):
            PROBE.database_counts(self.db)

    def test_integrity_result_must_be_ok(self):
        class Cursor:
            def fetchall(self):
                return [("corrupt page",)]

        class Connection:
            def __enter__(self):
                return self

            def __exit__(self, *_):
                return False

            def execute(self, _):
                return Cursor()

        with patch.object(PROBE.sqlite3, "connect", return_value=Connection()):
            with self.assertRaisesRegex(ValueError, "integrity"):
                PROBE.database_counts(self.db)

    def test_newer_archive_preserves_all_other_members(self):
        output = self.root / "future.enc"
        with tarfile.open(self.archive) as archive:
            PROBE.future_archive(archive, output, self.root)
        plain = self.root / "future-plain.tar.gz"
        PROBE.crypt(output, plain, decrypt=True)
        with tarfile.open(plain) as future, tarfile.open(self.archive) as original:
            self.assertEqual(original.getnames(), future.getnames())
            for member in original:
                if not member.isfile():
                    continue
                data = future.extractfile(member.name).read()
                if member.name.endswith("/config.json"):
                    self.assertEqual(json.loads(data)["config_version"], "2.1.1")
                else:
                    self.assertEqual(original.extractfile(member).read(), data)

    def test_real_encryption_rejects_truncated_archive(self):
        encrypted = self.root / "backup.enc"
        PROBE.crypt(self.archive, encrypted)
        encrypted.write_bytes(encrypted.read_bytes()[:1024])
        plain = self.root / "truncated.tar.gz"
        with self.assertRaises((subprocess.CalledProcessError, tarfile.TarError, EOFError)):
            PROBE.crypt(encrypted, plain, decrypt=True)
            with tarfile.open(plain) as archive:
                for member in archive:
                    if member.isfile():
                        archive.extractfile(member).read()


if __name__ == "__main__":
    unittest.main()
