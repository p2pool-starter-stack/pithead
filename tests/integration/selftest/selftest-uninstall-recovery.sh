#!/usr/bin/env bash
# #2343 job 635: a failure inside the uninstall phase left the box stranded for the harness's
# generic safety rollback, whose 240s wait is sized for a hot apply, not a full re-provision — the
# rollback itself then timed out. _uninstall_phase_recover is the phase's own recovery: restore the
# pre-run safety archive and bring the stack back, whether or not the outer rollback runs at all.
# This proves that trap fires on a real failure and stays silent otherwise, without a live bench.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=tests/integration/lib.sh
source "$HERE/../lib.sh"

SRC="$(sed -n '/^_uninstall_phase_recover() {/,/^}$/p' "$HERE/../lib/run-uninstall.sh")"
assert_contains "the recovery trap is extractable" "$(printf '%s\n' "$SRC" | head -n1)" "_uninstall_phase_recover() {"
assert_eq "the extraction is the whole function (closes)" "$(printf '%s\n' "$SRC" | tail -n1)" "}"

DIRS_SRC="$(sed -n '/^_uninstall_data_dirs() {/,/^}$/p' "$HERE/../lib/run-uninstall.sh")"
assert_contains "the data-directory reader is extractable" "$(printf '%s\n' "$DIRS_SRC" | head -n1)" "_uninstall_data_dirs() {"
LISTING_SRC="$(sed -n '/^_uninstall_dir_listing() {/,/^}$/p' "$HERE/../lib/run-uninstall.sh")"
assert_contains "the data snapshot reads root-owned Tor state with noninteractive sudo" "$LISTING_SRC" "sudo -n bash -o pipefail"

PHASE="$(sed -n '/^run_uninstall_phase() {/,/^}$/p' "$HERE/../lib/run-uninstall.sh")"
assert_contains "the rebuilt stack is checked against its kept config" "$PHASE" \
    "assert_running_state \"uninstall\" \"\$config_before\" \"\$setup_secret_fp\""
assert_contains "the rebuilt proxy and onion state must be populated" "$PHASE" \
    "grep -qE '^PROXY_AUTH_TOKEN=.+\$' .env"
assert_contains "the preservation snapshot includes backups" "$PHASE" "backups"
assert_contains "the preservation snapshot hashes file contents" "$PHASE" "_uninstall_snapshot_dirs"
assert_contains "the keep-list uses the decoded data-directory reader" "$PHASE" "_uninstall_data_dirs"
assert_contains "the keep-list requires every configured data directory" "$PHASE" "[ \"\$dir_count\" -ne 5 ]"
assert_contains "the config snapshot hashes the file bytes on the box" "$PHASE" "_uninstall_file_hash config.json"
assert_contains "container cleanup checks the pre-uninstall inventory without .env" "$PHASE" "compose_ids_before"
assert_contains "container cleanup requires a working Docker inventory" "$PHASE" "docker container ls -aq --no-trunc"
assert_contains "unit cleanup uses successful unfiltered systemd inventories" "$PHASE" "systemctl list-unit-files --no-legend && systemctl list-units --all --no-legend"
assert_contains "the snapshot stops services without preempting uninstall cleanup" "$PHASE" "docker compose stop >/dev/null"

PITHEAD_LOG="$(mktemp)"
DIRS_FIXTURE="$(mktemp -d)"
trap 'rm -f "$PITHEAD_LOG"; rm -rf "$DIRS_FIXTURE"' EXIT
pithead() { printf '%s\n' "$*" >>"$PITHEAD_LOG"; }
it_warn() { :; }
wait_status_ok() { return 0; }
SAFETY_ARCHIVE="/tmp/pithead-backup-fixture.tar.gz"
eval "$SRC"

# shellcheck disable=SC2016  # the fixture is a separate shell sourced by _uninstall_data_dirs.
printf '%s\n' \
    'env_get_file() { local line; line=$(grep -E "^$2=" "$1"); printf "%s" "${line#*=}"; }' \
    >"$DIRS_FIXTURE/pithead"
printf '%s\n' \
    'MONERO_DATA_DIR=/data/monero' \
    'TARI_DATA_DIR=/data/tari' \
    'P2POOL_DATA_DIR=/data/p2pool' \
    'DASHBOARD_DATA_DIR=/data/dashboard' \
    'TOR_DATA_DIR=/data/tor' \
    >"$DIRS_FIXTURE/.env"
rx() { bash -c "$1"; }
eval "$DIRS_SRC"
dirs_output="$(cd "$DIRS_FIXTURE" && _uninstall_data_dirs)"
assert_eq "the decoded data-directory reader emits five lines" "$(printf '%s\n' "$dirs_output" | wc -l | tr -d ' ')" "5"

# IT_FAIL is lib.sh's own real pass/fail counter (assert_eq increments it on a failed assertion
# below), and the function under test reads that SAME global — restore it right after each call so
# the simulated input never corrupts this selftest's own verdict.
echo "== a failure during the destructive step triggers recovery =="
real_fail="$IT_FAIL"
IT_FAIL=$((real_fail + 3))
_uninstall_phase_recover "$real_fail" # grew past the pre-destructive count: recover
IT_FAIL="$real_fail"
assert_eq "recovery brings the stack down first" "$(grep -c '^down$' "$PITHEAD_LOG")" "1"
assert_eq "recovery restores the exact pre-run archive" \
    "$(grep -c -F "restore -y $SAFETY_ARCHIVE" "$PITHEAD_LOG")" "1"
assert_eq "recovery brings the stack back up" "$(grep -c '^up$' "$PITHEAD_LOG")" "1"

echo "== no new failure means no recovery action =="
: >"$PITHEAD_LOG"
real_fail="$IT_FAIL"
_uninstall_phase_recover "$real_fail" # unchanged since the pre-destructive count: nothing to fix
IT_FAIL="$real_fail"
assert_eq "an unchanged failure count calls pithead nothing" "$(wc -l <"$PITHEAD_LOG" | tr -d ' ')" "0"

echo "selftest-uninstall-recovery: $IT_PASS passed, $IT_FAIL failed"
[ "$IT_FAIL" -eq 0 ]
