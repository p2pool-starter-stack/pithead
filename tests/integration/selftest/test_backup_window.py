"""Pure fixtures for the versioned backup result; no daemon or SSH."""

import copy
import importlib.util
import json
import os
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

SPEC = importlib.util.spec_from_file_location(
    "backup_window", Path(__file__).parents[1] / "lib/backup-window.py"
)
window = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(window)
TOKEN = "a" * 32


def initial():
    return {
        "invocation": TOKEN,
        "tor_event": "unknown",
        "execution": "unknown",
        "execution_observations": [],
    }


def observation(kind="backup_begin", **changes):
    value = {
        "version": 1,
        "token": TOKEN,
        "kind": kind,
        "observed_at": "2026-01-01T01:00:01Z",
        "container_id": "b" * 64,
        "image_id": "sha256:" + "c" * 64,
        "health": "healthy",
        "configured_test_sha256": "d" * 64,
        "implementation_sha256": None,
        "checks": [],
    }
    value.update(changes)
    return value


def transcript(*values):
    return "\n".join(window.PREFIX + json.dumps(value) for value in values)


class BackupWindowTests(unittest.TestCase):
    def test_nanosecond_window_does_not_include_adjacent_executions(self):
        begin = observation(observed_at="2026-01-01T01:00:01.123456900Z")
        for start, end, expected in (
            ("123456100", "123456800", "unknown"),  # Entirely before the window.
            ("123456800", "123456950", "unknown"),  # Straddles window admission.
            ("123456950", "123456999", "unknown"),  # Ends after the sample.
            ("123456900", "123456980", "observed"),
        ):
            with self.subTest(start=start, end=end):
                sample = observation(
                    "restart_succeeded",
                    observed_at="2026-01-01T01:00:01.123456980Z",
                    checks=[
                        {
                            "start": "2026-01-01T01:00:01." + start + "Z",
                            "end": "2026-01-01T01:00:01." + end + "Z",
                            "exit_code": 0,
                        }
                    ],
                )
                result = window.finish(initial(), 0, True, transcript(begin, sample))
                self.assertEqual(result["execution"], expected)
                self.assertEqual(
                    result["execution_observations"],
                    [{"observation": 1, "check": 0}] if expected == "observed" else [],
                )

    def test_inverted_nanosecond_interval_invalidates_observations(self):
        sample = observation(
            "restart_failed",
            health="unhealthy",
            checks=[
                {
                    "start": "2026-01-01T01:00:01.123456900Z",
                    "end": "2026-01-01T01:00:01.123456800Z",
                    "exit_code": 1,
                }
            ],
        )
        with self.assertRaises(ValueError):
            window.validate_observation(sample, TOKEN)
        result = window.finish(initial(), 7, False, transcript(observation(), sample))
        self.assertEqual(result["observation_channel"], "invalid")
        self.assertEqual(result["execution"], "unknown")
        self.assertEqual(result["tor_event"], "unknown")
        self.assertEqual(result["backup_exit_code"], 7)

    def test_timestamp_ordering_preserves_precision_and_equivalent_forms(self):
        self.assertLess(
            window.timestamp("2026-01-01T01:00:01.123456800Z"),
            window.timestamp("2026-01-01T01:00:01.123456900Z"),
        )
        self.assertLess(
            window.timestamp("2026-01-01T01:00:01.999999999Z"),
            window.timestamp("2026-01-01T01:00:02Z"),
        )
        for fraction in ("", ".0", ".000000000"):
            self.assertEqual(
                window.timestamp("2026-01-01T01:00:01" + fraction + "Z"),
                window.timestamp("2026-01-01T01:00:01.000000000+00:00"),
            )
        self.assertEqual(
            window.timestamp("2026-01-01T01:00:01.1Z"),
            window.timestamp("2026-01-01T01:00:01.100000000+00:00"),
        )

    def test_stable_event_despite_changing_diagnostics(self):
        events = []
        for day, tail in (("01", "control connections"), ("02", "bootstrap stalled")):
            stamp = f"2026-01-{day}T01:00:01Z"
            text = transcript(
                observation(observed_at=stamp),
                observation("restart_failed", health="unhealthy", observed_at=stamp),
            )
            value = window.finish(initial(), 3, False, text + "\n" + tail)
            self.assertEqual(value["backup_exit_code"], 3)
            events.append(value["tor_event"])
        self.assertEqual(events, ["tor_restart_failed", "tor_restart_failed"])

    def test_success_is_independent_of_later_wallet_failure(self):
        result = window.finish(initial(), 0, True, "archive written\nwallet prerequisite failed")
        self.assertEqual((result["outcome"], result["reason"]), ("succeeded", "archive_valid"))
        self.assertEqual(result["tor_event"], "unknown")

    def test_archive_missing_and_command_exit_are_distinct(self):
        for code, archive, reason in ((0, False, "archive_invalid"), (7, True, "command_failed")):
            value = window.finish(initial(), code, archive, "")
            self.assertEqual(value["outcome"], "failed")
            self.assertEqual(value["reason"], reason)
            self.assertEqual(value["backup_exit_code"], code)

    def test_execution_requires_in_window_observation_and_identity(self):
        check = {"start": "2026-01-01T01:00:02Z", "end": "2026-01-01T01:00:03Z", "exit_code": 1}
        end = observation(
            "restart_failed", health="unhealthy", observed_at="2026-01-01T01:00:04Z", checks=[check]
        )
        begin = observation()
        result = window.finish(initial(), 1, True, transcript(begin, end))
        self.assertEqual(result["execution"], "observed")
        self.assertEqual(result["execution_observations"], [{"observation": 1, "check": 0}])
        self.assertIsNone(result["observations"][1]["implementation_sha256"])
        for changes in (
            {"container_id": None},
            {"image_id": None},
            {"configured_test_sha256": None},
            {"checks": []},
            {"observed_at": "2026-01-01T01:00:02Z"},
        ):
            value = copy.deepcopy(end)
            value.update(changes)
            self.assertEqual(
                window.finish(initial(), 1, True, transcript(begin, value))["execution"], "unknown"
            )
        self.assertEqual(window.finish(initial(), 1, True, transcript(end))["execution"], "unknown")

    def test_bad_fields_are_not_public_events(self):
        unsafe = [
            "private.internal",
            "192.168.3.4",
            "/home/user/key",
            "cookie=secret",
            "AUTHENTICATE secret",
            "\x1b[31m",
            "x" * 9000,
        ]
        for text in unsafe:
            for key in (
                "container_id",
                "image_id",
                "configured_test_sha256",
                "implementation_sha256",
                "kind",
                "health",
                "observed_at",
            ):
                value = observation("restart_failed", health="unhealthy")
                value[key] = text
                result = window.finish(initial(), 9, False, transcript(value))
                self.assertEqual(result["observations"], [])
                self.assertEqual(result["tor_event"], "unknown")
                self.assertNotIn(text, json.dumps(result))
        for changes in (
            {"token": "b" * 32},
            {"extra": "secret"},
            {"checks": [{"Output": "secret"}]},
            {"version": True},
            {"checks": [None]},
            {
                "checks": [
                    dict(start="2026-01-01T01:00:03Z", end="2026-01-01T01:00:02Z", exit_code=1)
                ]
            },
        ):
            result = window.finish(initial(), 9, False, transcript(observation(**changes)))
            self.assertEqual(result["observation_channel"], "invalid")
            self.assertEqual(result["backup_exit_code"], 9)

    def test_bounded_channel_and_old_producer(self):
        self.assertEqual(
            window.finish(initial(), 1, False, "Tor unhealthy")["tor_event"], "unknown"
        )
        self.assertEqual(
            window.finish(initial(), 1, False, transcript(*[observation()] * 8))[
                "observation_channel"
            ],
            "invalid",
        )

    def test_identity_is_separate_and_validated(self):
        self.assertEqual(window.identity(["a" * 40, "b" * 64, "dirty"])["checkout_clean"], False)
        self.assertEqual(window.identity(["main", "cookie", "clean"])["source_commit"], None)
        self.assertEqual(window.identity([])["executable_sha256"], None)

    def test_initial_not_run_atomic_and_fresh(self):
        with tempfile.TemporaryDirectory() as parent:
            with patch("builtins.print") as output:
                window.initialize(parent)
                first = Path(output.call_args.args[0])
                window.initialize(parent)
                second = Path(output.call_args.args[0])
            self.assertNotEqual(first, second)
            directory, result = window.read(first)
            self.assertEqual(result["attempt"], "not_run")
            self.assertEqual(result["outcome"], "unknown")
            self.assertIsNone(result["backup_exit_code"])
            window.atomic_write(directory, result)
            self.assertEqual(list(directory.iterdir()), [directory / "result.json"])
            self.assertEqual(os.stat(directory / "result.json").st_mode & 0o777, 0o600)
            result["invocation"] = "b" * 32
            window.atomic_write(directory, result)
            with self.assertRaises(ValueError):
                window.read(directory)

    def test_unsafe_output_directory(self):
        with tempfile.TemporaryDirectory() as parent:
            linked = Path(parent) / "link"
            linked.symlink_to(parent, target_is_directory=True)
            with self.assertRaises(ValueError):
                window.initialize(linked)
            os.chmod(parent, 0o777)  # noqa: S103 - refusal fixture
            with self.assertRaises(ValueError):
                window.initialize(parent)
