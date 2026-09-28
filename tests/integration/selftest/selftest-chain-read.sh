#!/usr/bin/env bash
# A read-guarded chain-safe run never recreates a protected container on drift.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=tests/integration/lib.sh
source "$HERE/../lib.sh"
# shellcheck source=tests/integration/lib/chain-keep.sh
source "$HERE/../lib/chain-keep.sh"

echo "== chain-safe read lease =="
before=$'monerod m1 T1 sha256:m\ntari t1 T1 sha256:t\ntor o1 T1 sha256:o'
E2E_DIR=/e2e RESTORE_DIR=/base CHAIN_BEFORE="$before" CHAIN_SERVICES='monerod tari'
chain_snapshot() { printf '%s\n' "${NOW:-$before}"; }
chain_fingerprint() { [ "$1:$2" = "/e2e:${CHANGED:-none}" ] && echo 'config=changed files=f' || echo 'config=c files=f'; }
chain_image_of() { case "$2" in monerod) echo sha256:m ;; tari) echo sha256:t ;; tor) echo sha256:o ;; esac }
chain_baseline_current() { echo yes; }
warn() { :; }

chain_read_unchanged
assert_rc "unchanged nodes and Tor pass the late check" "$?" 0
CHANGED=tari chain_read_unchanged
assert_rc "changed Tari definition refuses the late operation" "$?" 1
CHANGED=tor chain_read_unchanged
assert_rc "changed Tor definition refuses the late operation" "$?" 1
NOW=$'monerod m1 T2 sha256:m\ntari t1 T1 sha256:t\ntor o1 T1 sha256:o' chain_read_unchanged
assert_rc "restarted monerod refuses restore" "$?" 1
NOW=$'monerod m1 T2 sha256:m\ntari t1 T1 sha256:t\ntor o1 T1 sha256:o' chain_read_restore_prepare
assert_rc "late restart refuses restore before upgrade" "$?" 1
chain_read_restore_prepare
assert_rc "unchanged restore preparation succeeds" "$?" 0

CI_CHAIN_SAFE_READ=1
commands="$(mktemp)"
trap 'rm -f "$commands"' EXIT
on_bench() { printf '%s\n' "$1" >>"$commands"; }
chain_read_unchanged() { [ "${LATE_OK:-yes}" = yes ]; }
deploy_keeping_chain
assert_rc "read guarded deploy succeeds when unchanged" "$?" 0
assert_contains "upgrade holds both nodes and Tor" "$(cat "$commands")" "CI_CHAIN_SAFE_READ=1 PITHEAD_KEEP_RUNNING='monerod tari tor' ./pithead upgrade"
assert_eq "no second up under a read lease" "$(grep -c './pithead up$' "$commands")" 0
: >"$commands"
LATE_OK=no deploy_keeping_chain
assert_rc "late difference fails before a second up" "$?" 1
assert_eq "late difference does not recreate" "$(grep -c './pithead up$' "$commands")" 0

(
    # shellcheck source=lib/pithead/32-onion-provisioning.sh
    source "$HERE/../../../lib/pithead/32-onion-provisioning.sh"
    error() { exit 1; }
    compose_up() { echo touched >>"$commands"; }
    MONERO_MODE=local MONERO_ONION=placeholder TARI_MODE=remote TARI_ONION=placeholder
    PITHEAD_KEEP_RUNNING='monerod tari tor'
    provision_node_onions
)
assert_rc "read guarded upgrade refuses missing onion before Tor up" "$?" 1
assert_eq "onion refusal leaves Tor alone" "$(grep -c touched "$commands")" 0

(
    source "$HERE/../../../lib/pithead/01-lifecycle.sh"
    PITHEAD_KEEP_RUNNING='monerod tari tor' CI_CHAIN_SAFE_READ=1
    docker() { printf '%s\n' dashboard tor tari; }
    container_is_running() { return 0; }
    warn() { :; }
    remove_deactivated_profile_containers() { echo touched >>"$commands"; }
    compose_up() { echo touched >>"$commands"; }
    compose_up_checked -d
)
assert_rc "inactive held node refuses before profile removal" "$?" 1
assert_eq "inactive node refusal touches no container" "$(grep -c touched "$commands")" 0
(
    source "$HERE/../../../lib/pithead/01-lifecycle.sh"
    PITHEAD_KEEP_RUNNING='monerod tari tor' CI_CHAIN_SAFE_READ=0
    docker() { printf '%s\n' dashboard tor tari; }
    container_is_running() { return 0; }
    resolve_pull_policy() { echo never; }
    log() { :; }
    remove_deactivated_profile_containers() { echo touched >>"$commands"; }
    compose_up() { echo touched >>"$commands"; }
    compose_up_checked -d
)
assert_rc "write path still reconciles inactive profile" "$?" 0
assert_eq "write path reaches normal remove and up" "$(grep -c touched "$commands")" 2
: >"$commands"

main_source="$(sed -n '/^main() {$/,/^}$/p' "$HERE/../e2e.sh")"
(
    eval "$main_source"
    # shellcheck disable=SC2034 # the evaluated main consumes these globals
    MODE=chain-safe CI_CHAIN_SAFE_READ=1 KEEP=0 BRANCH=test BENCH_HOST=test E2E_DIR=/e2e
    log() { :; }
    ok() { :; }
    preflight() { :; }
    provision() { :; }
    backup_stack() { echo backup >>"$commands"; }
    borrow_miner() { :; }
    deploy_branch() { :; }
    run_harness() { :; }
    main
)
assert_rc "read guarded main completes without a stopping backup" "$?" 0
assert_eq "read guarded main never invokes backup" "$(grep -c backup "$commands")" 0

restore_source="$(sed -n '/^restore_all() {$/,/^}$/p' "$HERE/../e2e.sh")"
: >"$commands"
(
    eval "$restore_source"
    # shellcheck disable=SC2034 # the evaluated restore_all consumes these globals
    MODE=chain-safe CI_CHAIN_SAFE_READ=1 RESTORED=0 KEEP=0 MINER_CFG_BACKUP=''
    # shellcheck disable=SC2034 # the evaluated restore_all consumes these globals
    RESTORE_DIR=/base BENCH_HOST=test SAFETY_ARCHIVE=''
    drain_harness_or_refuse() { :; }
    parent_lock_checkpoint() { :; }
    parent_lock_miner_restore() { :; }
    log() { :; }
    chain_read_unchanged() { return 1; }
    on_bench() { printf '%s\n' "$1" >>"$commands"; }
    restore_all
)
assert_rc "late difference exits the real restore trap" "$?" 1
assert_eq "late difference invokes no restore command" "$(grep -c "cd '/base'" "$commands")" 0

printf 'chain read self-test: %s passed, %s failed\n' "$IT_PASS" "$IT_FAIL"
[ "$IT_FAIL" -eq 0 ]
