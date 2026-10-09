"""Docker-free failure controls for the live retention assertion."""

import gzip
import importlib.util
import io
import json
import re
import tempfile
import unittest
from contextlib import redirect_stdout
from pathlib import Path
from unittest.mock import patch

SOURCE = Path(__file__).resolve().parents[1] / "lib/access_log_retention.py"
spec = importlib.util.spec_from_file_location("retention", SOURCE)
retention = importlib.util.module_from_spec(spec)
spec.loader.exec_module(retention)


class FakeCaddy:
    def __init__(self, logs, mode="correct"):
        self.logs = logs
        self.mode = mode
        self.rolls = 0
        self.records = []
        self.active = logs / "access.log"
        self.active.touch()

    def request(self, uri, wrong=False):
        if wrong and self.mode == "no-auth":
            return 200, ""
        if self.active.stat().st_size + len(uri) > 400000:
            self.rolls += 1
            # Caddy 2.11.4 pins timberjack 1.4.2: native size rotations carry -size.
            name = f"access-2026-10-09T01-00-{self.rolls:02d}.000-size.log.gz"
            (self.logs / name).write_bytes(gzip.compress(self.active.read_bytes()))
            self.active.write_bytes(b"")
        entry = {
            "uri": uri,
            "status": 401 if wrong else 404,
            "ts": 100000,
            "request": {"method": "GET", "uri": uri},
        }
        self.records.append(entry)
        with self.active.open("ab") as out:
            out.write(json.dumps(entry).encode() + b"\n")
        return entry["status"], ""

    def summary(self, sentinel):
        records = self.records
        if self.mode == "active-only":
            records = [json.loads(line) for line in self.active.read_bytes().splitlines()]
        elif self.mode == "old-tail":
            data = self.active.read_bytes()[-retention.OLD_TAIL :]
            records = [json.loads(line) for line in data.splitlines()[1:]]
        elif self.mode == "undercount":
            records = []
        selected = [r for r in records if r["uri"] == sentinel]
        failures = retention.expected_failures(self.logs, 100000)
        counter_cut = (
            self.mode == "counter-tail"
            and sentinel.encode() not in self.active.read_bytes()[-retention.OLD_TAIL :]
        )
        counter_rolled = (
            self.mode == "counter-rotation" and sentinel.encode() not in self.active.read_bytes()
        )
        if self.mode == "masked-counter" or counter_cut or counter_rolled:
            failures -= len(selected)
        return {"available": True, "entries": selected, "failures_24h": failures}


class RetentionControls(unittest.TestCase):
    def run_proof(self, mode="correct", clock=lambda: 0):
        with tempfile.TemporaryDirectory() as directory:
            client = FakeCaddy(Path(directory), mode)
            if mode in ("masked-counter", "counter-tail", "counter-rotation"):
                for _ in range(5):
                    client.request("/unrelated", wrong=True)
            output = io.StringIO()
            with redirect_stdout(output):
                retention.prove(
                    client, sleep=lambda _: None, clock=clock, wall_clock=lambda: 100000
                )
            return output.getvalue()

    def test_real_assertion_completes_all_phases(self):
        out = self.run_proof()
        self.assertIn("real wrong-password failures counted", out)
        self.assertIn("failures retained beyond 256 KiB", out)
        self.assertIn("failures retained after native gzip rotation", out)
        self.assertIn("access-log-retention: complete", out)

    def test_legacy_only_matcher_misses_native_rotation(self):
        legacy = re.compile(r"access-\d{4}-\d{2}-\d{2}T\d{2}-\d{2}-\d{2}\.\d{3}\.log(?:\.gz)?")
        with patch.object(retention, "_GENERATION", legacy):
            with self.assertRaisesRegex(RuntimeError, "did not rotate"):
                self.run_proof()

    def test_witness_deduplicates_legacy_and_native_names(self):
        with tempfile.TemporaryDirectory() as directory:
            logs = Path(directory)
            names = (
                "access-2026-10-09T01-00-01.000.log.gz",
                "access-2026-10-09T01-00-01.000-size.log",
                "access-2026-10-08T01-00-01.000.log.gz",
                "access-2026-10-07T01-00-01.000-size.log.gz",
            )
            for name in names:
                (logs / name).touch()
            self.assertEqual(
                {p.name for p in retention.retained_paths(logs)},
                {"access.log", names[1], names[2]},
            )

    def test_original_reader_fails_after_tail_limit(self):
        with self.assertRaisesRegex(RuntimeError, "beyond the old 256 KiB tail"):
            self.run_proof("old-tail")

    def test_active_only_reader_fails_after_rotation(self):
        with self.assertRaisesRegex(RuntimeError, "after native Caddy rotation"):
            self.run_proof("active-only")

    def test_api_undercount_cannot_pass(self):
        with self.assertRaisesRegex(RuntimeError, "all three wrong-password"):
            self.run_proof("undercount")

    def test_background_failures_cannot_mask_counter_omissions(self):
        with self.assertRaisesRegex(RuntimeError, "all three wrong-password"):
            self.run_proof("masked-counter")

    def test_count_only_tail_loss_cannot_be_masked_by_background(self):
        with self.assertRaisesRegex(RuntimeError, "beyond the old 256 KiB tail"):
            self.run_proof("counter-tail")

    def test_count_only_rotation_loss_cannot_be_masked_by_background(self):
        with self.assertRaisesRegex(RuntimeError, "after native Caddy rotation"):
            self.run_proof("counter-rotation")

    def test_bounded_reader_rejects_large_and_special_files(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "access.log"
            path.write_bytes(b"x" * (retention.FILE_BYTES + 1))
            with self.assertRaisesRegex(RuntimeError, "per-file bound"):
                retention.log_bytes(path)
            path.write_bytes(b"ok")
            link = Path(directory) / "access-2026-10-09T01-00-01.000.log"
            link.symlink_to(path)
            with self.assertRaises(OSError):
                retention.log_bytes(link)
            link.unlink()
            retention.os.mkfifo(link)
            with self.assertRaisesRegex(RuntimeError, "regular file"):
                retention.log_bytes(link)
            path = Path(directory) / "large.log.gz"
            path.write_bytes(gzip.compress(b"x" * (retention.FILE_BYTES + 1)))
            with self.assertRaisesRegex(RuntimeError, "decompressed log"):
                retention.log_bytes(path)

    def test_authentication_bypass_cannot_pass(self):
        with self.assertRaisesRegex(RuntimeError, "real Caddy 401"):
            self.run_proof("no-auth")

    def test_deadline_cannot_pass(self):
        ticks = iter([0, 541])
        with self.assertRaisesRegex(RuntimeError, "deadline exceeded"):
            self.run_proof(clock=lambda: next(ticks))

    def test_wrapper_is_in_hardening_and_requires_exit_and_completion(self):
        hardening = SOURCE.with_name("run-hardening.sh").read_text()
        self.assertIn(
            'rx "timeout 600 python3 tests/integration/lib/access_log_retention.py"', hardening
        )
        self.assertIn("grep -qx 'access-log-retention: complete'", hardening)
        self.assertLess(
            hardening.index("access_log_retention.py"),
            hardening.index("# Restore the baseline ourselves"),
        )


if __name__ == "__main__":
    unittest.main()
