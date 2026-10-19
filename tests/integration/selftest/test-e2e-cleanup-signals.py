import os
import shutil
import signal
import subprocess
import tempfile
import time
import unittest
from pathlib import Path

INTEGRATION = Path(__file__).resolve().parents[1]
BASH = shutil.which("bash")
DRIVER = r"""
set -uo pipefail
set -- candidate
source "$TEST_WORK/e2e.sh"
MODE=targeted KEEP=0 BORROW_MINER=0 BENCH_HOST=fixture
RESTORE_DIR="$TEST_WORK" E2E_DIR="$TEST_WORK/branch"
SAFETY_ARCHIVE='' MINER_CFG_BACKUP='' SSH_OPTS=()
CI_JOB_DIR="$TEST_WORK" WALLET_CACHE_SNAPSHOT="$TEST_WORK/archive"
printf 'private fixture\n' >"$WALLET_CACHE_SNAPSHOT"
cp "$WALLET_CACHE_SNAPSHOT" "$TEST_WORK/original"
wallet_fixture_receipt ARMED
parent_lock_checkpoint() { :; }
parent_lock_miner_restore() { :; }
drain_harness_or_refuse() { :; }
chain_restore_prepare() { :; }
control_units_verdict() { echo on-target; }
recreate_test_checkout_containers() { :; }
cleanup_rotate_onion_fixture() { :; }
verify_restore_proof() { :; }
wait_synced() { :; }
wait_bench_healthy() { :; }
wait_restore_mining_ready() { :; }
wallet_scan_sample() { :; }
on_bench() { :; }
rx() { :; }
api_state() { printf '{"earnings":{"confirmed":{"reachable":true,"address_match":%s}}}' "$TEST_IDENTITY"; }
wait_for() {
    printf 'waiting\n' >"$TEST_WORK/readiness"
    for _ in {1..500}; do
        if [ -f "$TEST_WORK/release" ]; then
            shift 3
            "$@"
            return
        fi
        sleep .02
    done
    return 1
}
wallet_fixture_command() {
    printf '%s\n' "$1" >>"$TEST_WORK/actions"
    case "$1" in
    restore) cmp "$WALLET_CACHE_SNAPSHOT" "$TEST_WORK/original" && cp "$WALLET_CACHE_SNAPSHOT" "$TEST_WORK/live" ;;
    cleanup) cmp "$TEST_WORK/live" "$TEST_WORK/original" && rm "$WALLET_CACHE_SNAPSHOT" ;;
    *) return 1 ;;
    esac
}
printf 'started\n' >"$TEST_WORK/started"
case "$TEST_EXIT" in
term) kill -TERM "$$" ;;
failure) exit 7 ;;
success) exit 0 ;;
esac
"""


class CleanupSignals(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.work = Path(self.temp.name)
        source = (INTEGRATION / "e2e.sh").read_text()
        source = "\n".join(
            f'HERE="{INTEGRATION}"' if line.startswith("HERE=") else line
            for line in source.splitlines()
            if line != "main"
        )
        (self.work / "e2e.sh").write_text(source + "\n")
        self.log = (self.work / "output").open("w+")
        self.addCleanup(self.log.close)

    def start(self, initial="term", identity="true"):
        self.child = subprocess.Popen(  # noqa: S603
            [BASH, "-c", DRIVER],
            env={
                **os.environ,
                "TEST_WORK": str(self.work),
                "TEST_EXIT": initial,
                "TEST_IDENTITY": identity,
            },
            stdout=self.log,
            stderr=subprocess.STDOUT,
            start_new_session=True,
        )
        self.addCleanup(self.reap)
        self.until("readiness")

    def reap(self):
        try:
            os.killpg(self.child.pid, signal.SIGKILL)
        except ProcessLookupError:
            pass
        except PermissionError:
            if self.child.poll() is None:
                raise
        self.child.wait(timeout=5)

    def until(self, name):
        deadline = time.monotonic() + 8
        while time.monotonic() < deadline:
            if (self.work / name).exists():
                return
            if self.child.poll() is not None:
                break
            time.sleep(0.02)
        self.log.flush()
        self.fail(f"did not reach {name}: {(self.work / 'output').read_text()}")

    def terminate(self):
        self.assertIsNone(self.child.poll(), "cleanup terminated before readiness")
        os.killpg(self.child.pid, signal.SIGTERM)

    def receipt(self):
        return (self.work / "wallet-fixture-restore.state").read_text().strip()

    def actions(self):
        return (self.work / "actions").read_text().splitlines()

    def complete(self, expected):
        (self.work / "release").touch()
        result = self.child.wait(timeout=8)
        self.assertEqual(128 - result if result < 0 else result, expected)
        self.assertEqual(self.receipt(), "VERIFIED")
        self.assertEqual(self.actions(), ["restore", "cleanup"])
        self.assertFalse((self.work / "archive").exists())

    def test_term_during_cleanup(self):
        self.start(initial="success")
        self.terminate()
        self.complete(0)

    def test_repeated_term_after_cancellation(self):
        self.start()
        for _ in range(3):
            self.terminate()
            time.sleep(0.05)
        self.complete(143)

    def test_failed_run_status_survives_cleanup_term(self):
        self.start(initial="failure")
        self.terminate()
        self.complete(7)

    def test_identity_failure_retains_fixture(self):
        self.start(initial="failure", identity="false")
        self.terminate()
        (self.work / "release").touch()
        self.assertEqual(self.child.wait(timeout=8), 1)
        self.assertEqual(self.receipt(), "NOT_PROVEN")
        self.assertEqual(self.actions(), ["restore"])
        self.assertTrue((self.work / "archive").exists())

    def test_deadline_expiry_keeps_incomplete_receipt(self):
        self.start(initial="success")
        deadline = time.monotonic() + 0.4
        while time.monotonic() < deadline:
            self.terminate()
            time.sleep(0.05)
        self.assertIsNone(self.child.poll())
        os.killpg(self.child.pid, signal.SIGKILL)
        self.assertEqual(self.child.wait(timeout=5), -signal.SIGKILL)
        self.assertEqual(self.receipt(), "ARMED")
        self.assertEqual(self.actions(), ["restore"])
        self.assertTrue((self.work / "archive").exists())


if __name__ == "__main__":
    unittest.main()
