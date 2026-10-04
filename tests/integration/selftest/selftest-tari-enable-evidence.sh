#!/usr/bin/env bash
# The real transition leg retains evidence and restores after a failed assertion.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=tests/integration/lib.sh
source "$HERE/../lib.sh"
# shellcheck source=tests/integration/lib/run-tari-background-sync.sh
INTEGRATION_RUN_SUITE=1 source "$HERE/../lib/run-tari-background-sync.sh"

echo "== Tari enable evidence distinguishes stopped and recreated proxies =="
fixture="$(mktemp -d "${TMPDIR:-${RUNNER_TEMP:?}}/tari-enable-selftest.XXXXXX")" || exit 1
trap 'rm -rf "$fixture"' EXIT
bad=0
for CASE in recreated stopped unchanged never-syncing stale-hashes; do
    OUT_DIR="$fixture/$CASE"
    mkdir -p "$OUT_DIR"
    PHASE=0
    FAILURE_COUNT=0
    CONTINUITY_PASSES=0
    printf '0\n' >"$OUT_DIR/polls"
    env_on_box() { printf local; }
    push_config() { PHASE=$((PHASE + 1)); }
    pithead() { printf 'apply-completed\n'; }
    wait_stratum_hashes() { return 0; }
    wait_status_ok() { return 0; }
    now_s() { printf 1; }
    sleep() { :; }
    it_fail() { FAILURE_COUNT=$((FAILURE_COUNT + 1)); }
    it_pass() {
        [ "$1" != "xmrig-proxy stays up during Tari enable/sync (#3094)" ] || CONTINUITY_PASSES=$((CONTINUITY_PASSES + 1))
        return 0
    }
    assert_eq() { [ "$2" = "$3" ] || it_fail; }
    capture_artifacts() { printf 'captured\n' >"$2/$1/captured"; }
    service_state() {
        if [ "$CASE:$PHASE" = stopped:2 ]; then printf 'stopped none'; else printf 'running healthy'; fi
    }
    rx() {
        case "$1" in
        'cat config.json') printf '{}' ;;
        *"{{.State.StartedAt}}' xmrig-proxy")
            if [ "$CASE:$PHASE" = recreated:2 ]; then printf new-start; else printf old-start; fi
            ;;
        *"{{.Name}} id="*) printf 'proxy state observed\n' ;;
        'docker logs --tail 100 dashboard') printf 'gate transition observed\n' ;;
        *) return 1 ;;
        esac
    }
    api_state() {
        local poll=0 sync_state="done" height=42
        if [ "$PHASE" = 2 ]; then
            poll=$(($(cat "$OUT_DIR/polls") + 1))
            printf '%s\n' "$poll" >"$OUT_DIR/polls"
            height=43
            [ "$poll" -ge 4 ] || sync_state="syncing"
            [ "$CASE" != never-syncing ] || sync_state="done"
        fi
        local hashes=$((poll * 100))
        [ "$CASE" != stale-hashes ] || hashes=100
        printf '{"timestamp":1,"proxy_workers":1,"stratum":{"total_hashes":%s},"sync":{"monero":{"state":"done"},"tari":{"state":"%s","secret":"must-not-be-retained"}},"tari":{"active":true,"connected":true,"height":"%s"},"badges":[],"secret":"must-not-be-retained"}' \
            "$hashes" "$sync_state" "$height"
    }
    rc=0
    run_tari_background_sync || rc=$?
    [ "$PHASE" = 3 ] || bad=$((bad + 1))
    [ -s "$OUT_DIR/tari-enable/off.apply.log" ] && [ -s "$OUT_DIR/tari-enable/on.apply.log" ] || bad=$((bad + 1))
    grep -q 'phase=after-restore' "$OUT_DIR/tari-enable/snapshots.log" || bad=$((bad + 1))
    if grep -q must-not-be-retained "$OUT_DIR/tari-enable/snapshots.log"; then bad=$((bad + 1)); fi
    if [ -f "$OUT_DIR/tari-enable/samples.jsonl" ] && grep -q must-not-be-retained "$OUT_DIR/tari-enable/samples.jsonl"; then bad=$((bad + 1)); fi
    if [ "$CASE" = recreated ] || [ "$CASE" = stopped ]; then
        [ "$CONTINUITY_PASSES" = 0 ] || bad=$((bad + 1))
    else
        [ "$CONTINUITY_PASSES" = 1 ] || bad=$((bad + 1))
    fi
    if [ "$CASE" = unchanged ]; then
        [ "$rc:$FAILURE_COUNT" = 0:0 ] || bad=$((bad + 1))
    else
        [ "$rc" = 1 ] && [ "$FAILURE_COUNT" -gt 0 ] || bad=$((bad + 1))
        [ -s "$OUT_DIR/tari-enable/dashboard.log" ] && [ -s "$OUT_DIR/tari-enable/captured" ] || bad=$((bad + 1))
        if [ "$CASE" = never-syncing ] || [ "$CASE" = stale-hashes ]; then
            [ "$FAILURE_COUNT" = 1 ] || bad=$((bad + 1))
            [ -s "$OUT_DIR/tari-enable/samples.jsonl" ] || bad=$((bad + 1))
            jq -e -s 'length > 0 and all(.[]; has("observed") and has("hashes") and has("tari_sync") and (has("secret") | not))' "$OUT_DIR/tari-enable/samples.jsonl" >/dev/null || bad=$((bad + 1))
            continue
        fi
        grep -q 'phase=continuity-failure' "$OUT_DIR/tari-enable/snapshots.log" || bad=$((bad + 1))
        if [ "$CASE" = recreated ]; then
            grep -q 'state=running expected_start=old-start actual_start=new-start' "$OUT_DIR/tari-enable/snapshots.log" || bad=$((bad + 1))
        else
            grep -q 'state=stopped expected_start=old-start actual_start=old-start' "$OUT_DIR/tari-enable/snapshots.log" || bad=$((bad + 1))
        fi
    fi
done
printf 'Tari enable evidence selftest: %s failed assertions\n' "$bad"
[ "$bad" = 0 ]
