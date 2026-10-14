"""Pure bounds, privacy and unavailable-probe controls; invoked by the shell selftest."""

import importlib.util
import json
import tempfile
import time
import unittest
from pathlib import Path
from unittest.mock import patch

spec = importlib.util.spec_from_file_location(
    "recovery", Path(__file__).resolve().parents[1] / "lib/node_recovery_evidence.py"
)
recovery = importlib.util.module_from_spec(spec)
spec.loader.exec_module(recovery)


class RecoveryEvidence(unittest.TestCase):
    def test_bound_and_original_exit(self):
        metadata, raw = recovery.probe(
            "rx() { python3 -c 'import sys; sys.stdout.write(\"x\" * 200000)'; return 17; }",
            "ignored",
        )
        self.assertEqual(metadata["exit_code"], 17)
        self.assertTrue(metadata["truncated"])
        self.assertEqual(len(raw), recovery.LIMIT)
        self.assertEqual(metadata["bytes_observed"], 200000)

    def test_transport_and_inherited_writer_deadlines(self):
        for body in ("sleep 10", "sleep 10 & return 0", "exec 1>&-; sleep 10"):
            with self.subTest(body=body):
                started = time.monotonic()
                metadata, _ = recovery.probe("rx() { " + body + "; }", "ignored", 0.1)
                self.assertTrue(metadata["timed_out"])
                self.assertEqual(metadata["exit_code"], 124)
                self.assertLess(time.monotonic() - started, 3)

    def test_status_privacy_and_complete_lines(self):
        hostile = (
            "\x1b[31m  ⚠ monerod   running but UNHEALTHY\x1b[0m\n"
            "  ✓ monerod running PASSWORD=private-value\n"
            "  ✓ private-service running\n"
            "wallet=private-value\nonion=private-value\n"
        ).encode()
        out = recovery.status_output(hostile)
        self.assertEqual(out["service_verdict_lines"], ["⚠ monerod   running but UNHEALTHY"])
        self.assertEqual(out["omitted_lines"], 4)
        self.assertNotIn("private", json.dumps(out))
        out = recovery.status_output("  ✓ monerod running".encode(), truncated=True)
        self.assertEqual(out["service_verdict_lines"], [])

    def test_unavailable_projections_are_explicit(self):
        for raw in (b"not json", b"[]", b"", b"{}"):
            for truncated in (False, True):
                with (
                    self.subTest(raw=raw, truncated=truncated),
                    tempfile.TemporaryDirectory() as tmp,
                ):
                    target = Path(tmp) / "evidence.json"
                    metadata = {"exit_code": 0, "truncated": truncated, "timed_out": False}
                    with (
                        patch.object(
                            recovery.sys,
                            "argv",
                            ["collector", "script", "status", str(target), "1", "240"],
                        ),
                        patch.object(
                            recovery,
                            "probe",
                            side_effect=[
                                ({**metadata, "exit_code": 19}, b""),
                                (dict(metadata), raw),
                                (dict(metadata), raw),
                            ],
                        ),
                        patch("builtins.print"),
                    ):
                        self.assertEqual(recovery.main(), 0)
                    evidence = json.loads(target.read_text())
                    self.assertEqual(evidence["status"]["exit_code"], 19)
                    self.assertFalse(evidence["services"]["projection_available"])
                    self.assertFalse(evidence["dashboard"]["projection_available"])

    def test_typed_projections(self):
        hostile = {
            "syncing": "private",
            "pool": {"type": "private", "sidechain_height": "private"},
            "sync": {"monero": {"state": "private", "current": True}},
            "monero": {"health": {"level": "private"}},
            "secret": "private",
        }
        out = recovery.dashboard(json.dumps(hostile).encode())
        self.assertNotIn("private", json.dumps(out))
        self.assertIsNone(out["sync"]["monero"]["current"])
        out = recovery.services(
            b'{"service":"monerod","state":"private","health":"private",'
            b'"restarts":"private","oom_killed":"private"}\n'
        )
        self.assertNotIn("private", json.dumps(out))
        for raw in (b"not json private", b"", b"{"):
            with self.assertRaises(ValueError):
                recovery.dashboard(raw)


if __name__ == "__main__":
    unittest.main()
