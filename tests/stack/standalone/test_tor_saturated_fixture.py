"""Exercise the actual offline guest script with daemon/control I/O replaced."""

import os
import shutil
import subprocess
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

FIXTURE = Path(__file__).with_name("test_tor_saturated_image.sh")

# These functions emulate only daemon I/O. The fixture's assertions, readiness,
# shutdown ordering, state moves and EXIT diagnostics execute unchanged under sh.
STUBS = r"""
tor() {
    starts=$((starts + 1))
    if [ "$mode" = start_failure ]; then
        echo 'fixture daemon refused startup' >>"$dir/offline.log"
        return 7
    fi
    if [ "$starts" = 1 ]; then
        case "$mode" in
            legacy) echo 'No valid circuit build time data' >>"$dir/offline.log" ;;
            unknown) echo 'fixture unexpected startup behavior' >>"$dir/offline.log" ;;
            *) echo 'CBT history has no completed observations; restarting conservative learning. samples=1000 abandoned=1000 usable=0' >>"$dir/offline.log" ;;
        esac
    fi
    printf '123\n' >"$dir/pid"
    printf 'PRIVATE_COOKIE\n' >"$dir/control_auth_cookie"
    running=true
    if [ "$starts" = 1 ] && [ "$mode" = legacy ]; then
        memory='CircuitBuildAbandonedCount 1000
TotalBuildTimes 1000'
    else
        memory='CircuitBuildAbandonedCount 0
TotalBuildTimes 0'
    fi
    if [ ! -e "$dir/state" ]; then
        printf '%s\n' "$memory" >"$dir/state"
    fi
}
kill() {
    if [ "$1" = -0 ]; then
        [ "$running" = true ]
    else
        if [ "$mode" = stop_failure ]; then return 8; fi
        running=false
        rm -f "$dir/pid"
        case "$mode" in
            false_repair) seed ;;
            retained_bin) printf 'CircuitBuildTimeBin 123 1\n' >"$dir/state" ;;
            failed_final) if [ "$starts" = 2 ]; then seed; else printf '%s\n' "$memory" >"$dir/state"; fi ;;
            nonzero_total) printf 'TotalBuildTimes 1\n' >"$dir/state" ;;
            repair) printf '# Tor minimal state file\n' >"$dir/state" ;;
            *) printf '%s\n' "$memory" >"$dir/state" ;;
        esac
    fi
}
nc() {
    if [ "$1" = -z ]; then [ "$running" = true ]; return; fi
    cat >/dev/null
    if [ "$mode" != readiness_failure ]; then printf '250 OK\n250-version=fixture\n250 OK\n'; fi
}
xxd() { printf 'PRIVATE_COOKIE\n'; }
sleep() { :; }
starts=0
running=false
"""


class OfflineTorFixtureTest(unittest.TestCase):
    def run_fixture(self, mode):
        with tempfile.TemporaryDirectory(
            dir=os.environ.get("TMPDIR") or os.environ.get("RUNNER_TEMP")
        ) as scratch:
            root = Path(scratch)
            docker = root / "docker"
            # Consume the very heredoc passed by the production wrapper. This also
            # tests pipeline failure propagation and the final completion marker.
            docker.write_text(
                "#!/usr/bin/env python3\n"
                "import os, subprocess, sys\n"
                "from pathlib import Path\n"
                "guest = sys.stdin.read().replace('/var/lib/tor', os.environ['GUEST_DIR'])\n"
                "guest = guest.replace('/usr/local/bin/tor-healthcheck.sh', 'false')\n"
                "prefix = Path(os.environ['STUB_FILE']).read_text()\n"
                "sys.exit(subprocess.run(['sh'], input=prefix + guest, text=True).returncode)\n"
            )
            docker.chmod(0o700)
            (root / "stubs").write_text(f"mode={mode}\n" + STUBS)
            (root / "guest").mkdir()
            result = subprocess.run(  # noqa: S603 -- checked-in fixture with fixed test modes
                [shutil.which("bash"), str(FIXTURE), "fixture-image"],  # noqa: S603 -- checked-in script and fixed modes
                env={
                    **os.environ,
                    "PATH": str(root) + os.pathsep + os.environ["PATH"],
                    "TMPDIR": str(root),
                    "GUEST_DIR": str(root / "guest"),
                    "STUB_FILE": str(root / "stubs"),
                },
                text=True,
                stdout=subprocess.PIPE,
                stderr=subprocess.STDOUT,
                timeout=10,
            )
        self.assertNotIn("PRIVATE_COOKIE", result.stdout)
        return result

    def test_automatic_repair_persists_and_manual_recovery_runs(self):
        result = self.run_fixture("repair")
        self.assertEqual(result.returncode, 0, result.stdout)
        self.assertIn("PASS: automatic repair persists an empty", result.stdout)
        self.assertIn("PASS: stop, move, start clears", result.stdout)
        self.assertIn("Tor offline recovery assertions complete", result.stdout)

    def test_legacy_shutdown_write_and_manual_recovery_run(self):
        result = self.run_fixture("legacy")
        self.assertEqual(result.returncode, 0, result.stdout)
        self.assertIn("PASS: saturated history emits", result.stdout)
        self.assertIn("PASS: moving state while Tor runs", result.stdout)
        self.assertIn("PASS: stop, move, start clears", result.stdout)

    def test_unrecognized_behavior_fails_with_offline_log(self):
        result = self.run_fixture("unknown")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("FAIL: offline Tor phase: classify", result.stdout)
        self.assertIn("fixture unexpected startup behavior", result.stdout)
        self.assertIn("CircuitBuildAbandonedCount 1000", result.stdout)
        self.assertNotIn("Tor offline recovery assertions complete", result.stdout)

    def test_claimed_repair_that_keeps_saturation_fails(self):
        result = self.run_fixture("false_repair")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn(
            "FAIL: offline Tor phase: assert CircuitBuildAbandonedCount is absent or zero",
            result.stdout,
        )
        self.assertNotIn("Tor offline recovery assertions complete", result.stdout)

    def test_nonzero_total_identifies_failed_assertion(self):
        result = self.run_fixture("nonzero_total")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn(
            "FAIL: offline Tor phase: assert TotalBuildTimes is absent or zero", result.stdout
        )

    def test_retained_bin_rejects_automatic_repair(self):
        result = self.run_fixture("retained_bin")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("assert no CircuitBuildTimeBin after automatic repair", result.stdout)
        self.assertNotIn("PASS: automatic repair persists", result.stdout)
        self.assertNotIn("Tor offline recovery assertions complete", result.stdout)

    def test_retained_saturation_rejects_final_recovery(self):
        result = self.run_fixture("failed_final")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("verify stop, move, start clears saturated history", result.stdout)
        self.assertNotIn("PASS: stop, move, start clears", result.stdout)
        self.assertNotIn("Tor offline recovery assertions complete", result.stdout)

    def test_platform_scratch_default_without_environment(self):
        environment = {
            key: value for key, value in os.environ.items() if key not in ("TMPDIR", "RUNNER_TEMP")
        }
        with patch.dict(os.environ, environment, clear=True):
            result = self.run_fixture("repair")
        self.assertEqual(result.returncode, 0, result.stdout)
        self.assertIn("Tor offline recovery assertions complete", result.stdout)

    def test_explicit_zero_defaults_are_accepted(self):
        result = self.run_fixture("zero_fields")
        self.assertEqual(result.returncode, 0, result.stdout)

    def test_start_failure_preserves_exit_and_log(self):
        result = self.run_fixture("start_failure")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("(exit 7)", result.stdout)
        self.assertIn("fixture daemon refused startup", result.stdout)

    def test_readiness_and_stop_failures_cannot_pass(self):
        for mode in ("readiness_failure", "stop_failure"):
            with self.subTest(mode=mode):
                result = self.run_fixture(mode)
                self.assertNotEqual(result.returncode, 0)
                self.assertIn("FAIL: offline Tor phase:", result.stdout)
                self.assertNotIn("Tor offline recovery assertions complete", result.stdout)


if __name__ == "__main__":
    unittest.main()
