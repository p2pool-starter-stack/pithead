import contextlib
import io
import json
import os
import runpy
import socket
import subprocess
import tempfile
import unittest
import urllib.error
from pathlib import Path
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[3]


class StratumPortTest(unittest.TestCase):
    def probe(
        self, port, active=3333, bind="0.0.0.0", action="validate_stratum_port_change", config=None
    ):
        with tempfile.TemporaryDirectory() as directory:
            env_file = Path(directory) / ".env"
            env_file.write_text(f"STRATUM_PORT={active}\n")
            config_file = Path(directory) / "config.json"
            document = (
                config
                if config is not None
                else {"p2pool": {"stratum_port": port, "stratum_bind": bind}}
            )
            config_file.write_text(json.dumps(document))
            result = subprocess.run(
                [
                    "/bin/bash",
                    "-c",
                    """
set -euo pipefail
source "$ROOT/lib/pithead/19-small-utilities.sh"
source "$ROOT/lib/pithead/22a-config-document.sh"
source "$ROOT/lib/pithead/27b-stratum-endpoint.sh"
source "$ROOT/lib/pithead/39a-stratum-port-preflight.sh"
source "$ROOT/lib/pithead/40-apply-and-render.sh"
error() { echo "$*" >&2; exit 1; }
require_env() { :; }
ensure_onion_password() { echo "reached mutation boundary"; exit 77; }
parse_and_validate_config() { :; }
load_preserved_state() { echo "reached mutation boundary"; exit 77; }
PITHEAD_ENV_DRYRUN="$ENV_FILE.dryrun"
case "$ACTION" in
    preview) apply --dry-run --porcelain ;;
    commit) apply -y ;;
    *) validate_stratum_port_change ;;
esac
""",
                ],
                env={
                    **os.environ,
                    "ROOT": str(ROOT),
                    "ENV_FILE": str(env_file),
                    "CONFIG_FILE": str(config_file),
                    "STRATUM_PORT": str(port),
                    "STRATUM_BIND": bind,
                    "ACTION": action,
                },
                capture_output=True,
                text=True,
                timeout=10,
            )
            self.assertEqual(json.loads(config_file.read_text()), document)
            self.assertEqual(env_file.read_text(), f"STRATUM_PORT={active}\n")
            return result

    def test_each_occupied_candidate_refused_before_preview_or_commit(self):
        with socket.socket() as first, socket.socket() as second:
            for listener in (first, second):
                listener.bind(("127.0.0.1", 0))
                listener.listen()
                for action in ("preview", "commit"):
                    with self.subTest(port=listener.getsockname()[1], action=action):
                        result = self.probe(listener.getsockname()[1], action=action)
                        self.assertEqual(result.returncode, 1, result.stderr)
                        self.assertIn("already in use", result.stderr)
                        self.assertNotIn("reached mutation boundary", result.stdout)

    def test_unchanged_active_port_allowed(self):
        with socket.socket() as listener:
            listener.bind(("127.0.0.1", 0))
            listener.listen()
            port = listener.getsockname()[1]
            self.assertEqual(self.probe(port, active=port).returncode, 0)

    def test_free_changed_port_allowed(self):
        with socket.socket() as listener:
            listener.bind(("127.0.0.1", 0))
            port = listener.getsockname()[1]
        self.assertEqual(self.probe(port).returncode, 0)

    def test_specific_bind_conflicts_with_matching_listener(self):
        with socket.socket() as listener:
            listener.bind(("127.0.0.1", 0))
            listener.listen()
            result = self.probe(listener.getsockname()[1], bind="127.0.0.1")
            self.assertEqual(result.returncode, 1, result.stderr)
            self.assertIn("already in use", result.stderr)

    def test_probe_does_not_reserve_port(self):
        with socket.socket() as listener:
            listener.bind(("127.0.0.1", 0))
            port = listener.getsockname()[1]
        self.assertEqual(self.probe(port).returncode, 0)
        with socket.socket() as listener:
            listener.bind(("127.0.0.1", port))
            listener.listen()
            result = self.probe(port, action="commit")
            self.assertEqual(result.returncode, 1, result.stderr)
            self.assertIn("already in use", result.stderr)

    def test_control_characters_refused_before_endpoint_diagnostics(self):
        for action in ("preview", "commit"):
            for port, bind in (
                ("443\nuntrusted-marker", "0.0.0.0"),
                (45678, "\x1b[31muntrusted-marker"),
            ):
                with self.subTest(action=action, port=port, bind=bind):
                    result = self.probe(port, bind=bind, action=action)
                    self.assertEqual(result.returncode, 1, result.stderr)
                    self.assertIn("control character", result.stderr)
                    self.assertNotIn("untrusted-marker", result.stderr)

    def test_omitted_endpoint_uses_unchanged_default(self):
        result = self.probe(3333, config={})
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_unavailable_address_fails_closed(self):
        result = self.probe(45678, bind="192.0.2.1")
        self.assertEqual(result.returncode, 1, result.stderr)
        self.assertIn("could not be checked", result.stderr)


class OccupiedStratumProofTest(unittest.TestCase):
    def exercise(self, samples, config_errors=(), stratum_source=None):
        clock = [0]
        state_reads = [0]
        previews = []
        output = io.StringIO()
        config_errors = iter(config_errors)

        def respond(req, **kwargs):
            route = req.full_url.split("/api/")[1]
            if route == "state":
                index = min(state_reads[0], len(samples) - 1)
                state_reads[0] += 1
                if isinstance(samples[index], dict):
                    value = samples[index]
                else:
                    workers, hashes = samples[index]
                    value = {"proxy_workers": workers, "stratum": {"total_hashes": hashes}}
            elif route == "config":
                error = next(config_errors, None)
                if error is not None:
                    raise error
                value = {"p2pool": {"stratum_port": 3333}}
            elif route == "control/preview":
                previews.append(state_reads[0])
                value = {"id": "test", "status": "rejected", "log": "already in use"}
            else:
                raise AssertionError(route)
            return io.StringIO(json.dumps(value))

        def sleep(seconds):
            clock[0] += seconds

        def read_source(*args, **kwargs):
            if stratum_source is None:
                raise FileNotFoundError
            return io.BytesIO(stratum_source.encode())

        error = None
        with (
            patch("sys.argv", ["occupied-stratum.py", "443"]),
            patch("urllib.request.urlopen", side_effect=respond),
            patch("time.monotonic", side_effect=lambda: clock[0]),
            patch("time.sleep", side_effect=sleep),
            patch("pathlib.Path.open", side_effect=read_source),
            contextlib.redirect_stdout(output),
        ):
            try:
                runpy.run_path(str(ROOT / "tests/integration/lib/occupied-stratum.py"))
            except AssertionError as exc:
                error = str(exc)
        return error, previews, output.getvalue()

    def test_initial_config_waits_for_dashboard_after_prior_apply(self):
        error, previews, output = self.exercise(
            [(1, 100), (1, 102), (1, 104)],
            [urllib.error.URLError(ConnectionRefusedError(111, "Connection refused"))],
        )
        self.assertIsNone(error)
        self.assertEqual(previews, [2])
        self.assertIn("mining continues", output)

    def test_initial_config_refusal_has_a_deadline(self):
        error, previews, _ = self.exercise(
            [(1, 100)],
            [urllib.error.URLError(ConnectionRefusedError(111, "Connection refused"))] * 100,
        )
        self.assertEqual(previews, [])
        self.assertIn("configuration unavailable before occupied-port preview", error)

    def test_initial_config_http_errors_are_not_retried(self):
        with self.assertRaises(urllib.error.HTTPError):
            self.exercise(
                [(1, 100), (1, 102), (1, 104)],
                [urllib.error.HTTPError("", 401, "Unauthorized", {}, None)],
            )

    def test_preview_waits_for_active_mining_after_prior_apply(self):
        error, previews, output = self.exercise([(0, 100), (1, 100), (1, 102), (1, 104)])
        self.assertIsNone(error)
        self.assertEqual(previews, [3])
        self.assertIn("mining continues", output)

    def test_prior_apply_counter_reset_requires_new_progress(self):
        error, previews, output = self.exercise([(1, 100), (1, 2), (1, 4), (1, 6)])
        self.assertIsNone(error)
        self.assertEqual(previews, [3])
        self.assertIn("hashes=2->4", output)

    def test_counter_reset_without_progress_never_previews(self):
        error, previews, _ = self.exercise([(1, 100), (1, 2)])
        self.assertEqual(previews, [])
        self.assertIn("before occupied-port preview", error)

    def test_post_refusal_counter_reset_does_not_pass_as_progress(self):
        error, previews, _ = self.exercise([(1, 100), (1, 102), (1, 2), (1, 4)])
        self.assertEqual(previews, [2])
        self.assertIn("after occupied-port refusal", error)

    def test_missing_mining_baseline_refuses_to_test_preview(self):
        error, previews, _ = self.exercise([(0, 100)])
        self.assertEqual(previews, [])
        self.assertIn("before occupied-port preview", error)
        self.assertIn("workers=0", error)
        self.assertIn("hashes=100", error)

    def test_post_preview_stall_fails_with_observed_counters(self):
        error, previews, _ = self.exercise([(1, 100), (1, 102), (1, 102)])
        self.assertEqual(previews, [2])
        self.assertIn("after occupied-port refusal", error)
        self.assertIn("workers=1", error)
        self.assertIn("hashes=102", error)

    def test_stall_samples_share_counters_and_snapshot_changes_with_a_bound(self):
        error, previews, output = self.exercise(
            [
                {"proxy_workers": 1, "stratum": {"total_hashes": 100}, "last_update": "before"},
                {
                    "proxy_workers": 1,
                    "stratum": {"total_hashes": 100, "total_shares": 4},
                    "proxy_summary": {"accepted": "2,000", "rejected": 3, "invalid": 0},
                    "last_update": "after",
                },
            ]
        )
        samples = [
            json.loads(line.removeprefix("mining sample "))
            for line in output.splitlines()
            if line.startswith("mining sample ")
        ]
        self.assertGreater(len(samples), 1)
        self.assertLessEqual(len(samples), 12)
        self.assertTrue(all(sample["snapshot_changed"] for sample in samples))
        self.assertTrue(all(sample["proxy_accepted"] == 2000 for sample in samples))
        self.assertTrue(all(sample["stratum_shares"] == 4 for sample in samples))
        self.assertEqual(previews, [])
        self.assertIn("before occupied-port preview", error)

    def test_mining_samples_omit_untrusted_counter_text_and_unrelated_fields(self):
        marker = "untrusted-marker"
        error, previews, output = self.exercise(
            [
                {
                    "proxy_workers": 1,
                    "stratum": {"total_hashes": 100, "wallet": marker},
                    "proxy_summary": {"accepted": marker},
                    "last_update": marker,
                }
            ]
        )
        self.assertNotIn(marker, output)
        self.assertIn('"proxy_accepted": null', output)
        self.assertIn('"snapshot_changed": false', output)
        self.assertEqual(previews, [])
        self.assertIn("before occupied-port preview", error)

    def test_source_progress_does_not_pass_a_stale_dashboard(self):
        error, previews, output = self.exercise(
            [(1, 100), (1, 102), (1, 102)],
            stratum_source=json.dumps({"total_hashes": 200, "total_stratum_shares": 7}),
        )
        self.assertEqual(previews, [2])
        self.assertIn("after occupied-port refusal", error)
        self.assertIn('"source_hashes": 200', output)
        self.assertIn('"source_shares": 7', output)

    def test_source_diagnostics_are_bounded_and_do_not_expose_raw_data(self):
        marker = "untrusted-marker"
        for raw, expected in (
            (marker, "unavailable"),
            (json.dumps({"total_hashes": marker, "wallet": marker}), "read"),
            (json.dumps({"total_hashes": 200, "extra": marker * 5000}), "unavailable"),
            ("[]", "unavailable"),
            (None, "unavailable"),
        ):
            with self.subTest(raw_type=type(raw).__name__):
                error, previews, output = self.exercise([(1, 100)], stratum_source=raw)
                self.assertNotIn(marker, output)
                self.assertEqual(previews, [])
                self.assertIn("before occupied-port preview", error)
                self.assertIn(f'"source_status": "{expected}"', output)
                self.assertNotIn('"source_hashes": 200', output)


if __name__ == "__main__":
    unittest.main()
