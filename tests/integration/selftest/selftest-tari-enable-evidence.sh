#!/usr/bin/env bash
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=tests/integration/lib.sh
source "$HERE/../lib.sh"
# shellcheck source=tests/integration/lib/run-tari-background-sync.sh
INTEGRATION_RUN_SUITE=1 source "$HERE/../lib/run-tari-background-sync.sh"

echo "== Tari enable evidence distinguishes stopped and recreated proxies =="
fixture="$(mktemp -d)" || exit 1
trap 'rm -rf "$fixture"' EXIT
bad=0
mkdir -p "$fixture/probe/mining_dashboard/client" "$fixture/probe/mining_dashboard/config"
printf '%s\n' 'class XMRigProxyClient:' ' def __init__(self, *_): pass' ' def get_summary(self): return {"miners":{"now":2},"results":{"hashes_total":7}}' >"$fixture/probe/mining_dashboard/client/xmrig_proxy_client.py"
printf '%s\n' 'import os' 'PROXY_HOST="fake"' 'PROXY_API_PORT=1' 'PROXY_AUTH_TOKEN="fake"' 'TARI_STATS_PATH=os.environ["FAKE_TARI_STATS_PATH"]' >"$fixture/probe/mining_dashboard/config/config.py"
printf '{"chains":[{"channel_state":"READY","height":43}]}\n' >"$fixture/probe/merge_mining"
rx() {
    local code="${1#*\'}"
    code="${code%\'}"
    FAKE_TARI_STATS_PATH="$fixture/probe/merge_mining" PYTHONPATH="$fixture/probe" python3 -c "$code"
}
probe_sample="$(tari_enable_mining_sample)"
probe_mtime="$(python3 -c 'import os,sys;print(int(os.stat(sys.argv[1]).st_mtime))' "$fixture/probe/merge_mining")"
jq -e --argjson mtime "$probe_mtime" '.workers == 2 and .hashes == 7 and .template_updated == $mtime and .receipt_state == "READY" and .receipt_height == 43' <<<"$probe_sample" >/dev/null || bad=$((bad + 1))
printf '{\n' >"$fixture/probe/merge_mining"
probe_sample="$(tari_enable_mining_sample)"
jq -e '.workers == 2 and .hashes == 7 and .template_updated == null and .receipt_state == null and .receipt_height == null' <<<"$probe_sample" >/dev/null || bad=$((bad + 1))
printf '\377' >"$fixture/probe/merge_mining"
probe_sample="$(tari_enable_mining_sample)"
jq -e '.workers == 2 and .hashes == 7 and .template_updated == null and .receipt_state == null and .receipt_height == null' <<<"$probe_sample" >/dev/null || bad=$((bad + 1))
rm "$fixture/probe/merge_mining"
probe_sample="$(tari_enable_mining_sample)"
jq -e '.workers == 2 and .hashes == 7 and .template_updated == null and .receipt_state == null and .receipt_height == null' <<<"$probe_sample" >/dev/null || bad=$((bad + 1))
unset -f rx
for CASE in recreated stopped unchanged same-height never-syncing loading-to-done stale-hashes decreasing-hashes no-workers late-stall probe-error missing-hashes sync-timeout disconnected stale-template missing-template null-template invalid-template stale-stats missing-stats invalid-stats malformed-stats receipt-disconnected receipt-mismatch missing-current invalid-current zero-current; do
    OUT_DIR="$fixture/$CASE"
    mkdir -p "$OUT_DIR"
    PHASE=0
    FAILURE_COUNT=0
    CONTINUITY_PASSES=0
    TEMPLATE_FAILURE=""
    printf '0\n' >"$OUT_DIR/polls"
    printf '0\n' >"$OUT_DIR/baseline-reads"
    env_on_box() { printf local; }
    push_config() {
        grep -qx 'height_before=42' "$OUT_DIR/tari-enable/snapshots.log" || FAILURE_COUNT=$((FAILURE_COUNT + 1))
        PHASE=$((PHASE + 1))
    }
    pithead() { printf 'apply-completed\n'; }
    wait_stratum_hashes() { return 0; }
    wait_status_ok() { return 0; }
    now_s() { printf '%s' "$((1 + $(cat "$OUT_DIR/polls") * 30))"; }
    sleep() { :; }
    it_fail() {
        FAILURE_COUNT=$((FAILURE_COUNT + 1))
        if [ "${1:-}" = "merge-mining templates arrive after Tari sync (#3094)" ]; then TEMPLATE_FAILURE="${2:-}"; fi
    }
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
        'docker exec dashboard python3 -c '*get_summary*)
            [ "$CASE" != probe-error ] || return 1
            if [ "$CASE" = missing-hashes ]; then
                printf '{"workers":1}'
                return 0
            fi
            local poll hashes workers=1 updated=1 receipt_state='"READY"' receipt_height=43
            poll="$(cat "$OUT_DIR/polls")"
            hashes=$((poll * 100))
            [ "$CASE" != stale-hashes ] || hashes=100
            [ "$CASE" != decreasing-hashes ] || hashes=$((10000 - poll * 100))
            [ "$CASE" != no-workers ] || workers=0
            if [ "$CASE" = late-stall ] && [ "$poll" -ge 3 ]; then hashes=300; fi
            if [ "$CASE" = missing-stats ]; then
                printf '{"workers":%s,"hashes":%s}' "$workers" "$hashes"
                return 0
            fi
            [ "$CASE" != stale-stats ] || updated=0
            [ "$CASE" != invalid-stats ] || updated='"invalid"'
            if [ "$CASE" = malformed-stats ]; then updated=null receipt_state=null receipt_height=null; fi
            [ "$CASE" != receipt-disconnected ] || receipt_state='"TRANSIENT_FAILURE"'
            [ "$CASE" != receipt-mismatch ] || receipt_height=44
            if [ "$CASE" = same-height ] || [ "$CASE" = stale-template ]; then receipt_height=42; fi
            printf '{"workers":%s,"hashes":%s,"template_updated":%s,"receipt_state":%s,"receipt_height":%s}' "$workers" "$hashes" "$updated" "$receipt_state" "$receipt_height"
            ;;
        'docker logs --tail 100 dashboard') printf 'gate transition observed\n' ;;
        *) return 1 ;;
        esac
    }
    api_state() {
        local poll=0 sync_state="done" sync_current=42 height=44 connected=true reads height_field
        if [ "$PHASE" = 0 ]; then
            reads="$(cat "$OUT_DIR/baseline-reads")"
            if [ "$CASE" = same-height ]; then
                sync_current=41
                height=42
            else
                [ "$reads" != 0 ] || height=42
            fi
            printf '%s\n' "$((reads + 1))" >"$OUT_DIR/baseline-reads"
        fi
        if [ "$PHASE" = 2 ]; then
            poll=$(($(cat "$OUT_DIR/polls") + 1))
            printf '%s\n' "$poll" >"$OUT_DIR/polls"
            height=43
            [ "$poll" -ge 4 ] || sync_state="syncing"
            [ "$CASE" != never-syncing ] || sync_state="done"
            if [ "$CASE" = loading-to-done ] && [ "$poll" -lt 4 ]; then sync_state="loading"; fi
            if [ "$CASE" = late-stall ] && [ "$poll" -lt 10 ]; then sync_state="loading"; fi
        fi
        if [ "$PHASE" = 2 ]; then
            case "$CASE" in
            sync-timeout) sync_state=syncing ;;
            disconnected) connected=false ;;
            same-height) sync_current=41 height=42 ;;
            stale-template) height=42 ;;
            null-template) height=null ;;
            invalid-template) height=invalid ;;
            missing-current) sync_current=null ;;
            invalid-current) sync_current='"invalid"' ;;
            zero-current) sync_current=0 ;;
            esac
        fi
        local hashes=$((poll * 100))
        [ "$CASE" != stale-hashes ] || hashes=100
        if [ "$CASE" = missing-template ] && [ "$PHASE" = 2 ]; then
            height_field=""
        elif [ "$CASE" = null-template ] && [ "$PHASE" = 2 ]; then
            height_field=',"height":null'
        else
            printf -v height_field ',"height":"%s"' "$height"
        fi
        printf '{"timestamp":1,"proxy_workers":1,"stratum":{"total_hashes":%s},"sync":{"monero":{"state":"done"},"tari":{"state":"%s","current":%s,"secret":"must-not-be-retained"}},"tari":{"active":true,"connected":%s%s},"badges":[],"secret":"must-not-be-retained"}' \
            "$hashes" "$sync_state" "$sync_current" "$connected" "$height_field"
    }
    rc=0
    run_tari_background_sync || rc=$?
    case "$CASE" in
    sync-timeout) expected='last_state=syncing (need done); last_connected=true (need true); last_sync_current=42 (need positive integer); last_template_updated=1 (need >= 1); last_receipt_state=READY (need READY); last_receipt_height=43 (need = 43); last_template_height=43 (need > 42)' ;;
    disconnected) expected='last_state=done (need done); last_connected=false (need true); last_sync_current=42 (need positive integer); last_template_updated=1 (need >= 1); last_receipt_state=READY (need READY); last_receipt_height=43 (need = 43); last_template_height=43 (need > 42)' ;;
    stale-template) expected='last_state=done (need done); last_connected=true (need true); last_sync_current=42 (need positive integer); last_template_updated=1 (need >= 1); last_receipt_state=READY (need READY); last_receipt_height=42 (need = 42); last_template_height=42 (need > 42)' ;;
    missing-template | null-template | invalid-template) expected='last_state=done (need done); last_connected=true (need true); last_sync_current=42 (need positive integer); last_template_updated=1 (need >= 1); last_receipt_state=READY (need READY); last_receipt_height=43 (need = valid API template height); last_template_height=unreadable (need > 42)' ;;
    stale-stats) expected='last_state=done (need done); last_connected=true (need true); last_sync_current=42 (need positive integer); last_template_updated=0 (need >= 1); last_receipt_state=READY (need READY); last_receipt_height=43 (need = 43); last_template_height=43 (need > 42)' ;;
    missing-stats | malformed-stats) expected='last_state=done (need done); last_connected=true (need true); last_sync_current=42 (need positive integer); last_template_updated=unreadable (need >= 1); last_receipt_state=unreadable (need READY); last_receipt_height=unreadable (need = 43); last_template_height=43 (need > 42)' ;;
    invalid-stats) expected='last_state=done (need done); last_connected=true (need true); last_sync_current=42 (need positive integer); last_template_updated=invalid (need >= 1); last_receipt_state=READY (need READY); last_receipt_height=43 (need = 43); last_template_height=43 (need > 42)' ;;
    receipt-disconnected) expected='last_state=done (need done); last_connected=true (need true); last_sync_current=42 (need positive integer); last_template_updated=1 (need >= 1); last_receipt_state=TRANSIENT_FAILURE (need READY); last_receipt_height=43 (need = 43); last_template_height=43 (need > 42)' ;;
    receipt-mismatch) expected='last_state=done (need done); last_connected=true (need true); last_sync_current=42 (need positive integer); last_template_updated=1 (need >= 1); last_receipt_state=READY (need READY); last_receipt_height=44 (need = 43); last_template_height=43 (need > 42)' ;;
    missing-current | invalid-current) expected='last_state=done (need done); last_connected=true (need true); last_sync_current=unreadable (need positive integer); last_template_updated=1 (need >= 1); last_receipt_state=READY (need READY); last_receipt_height=43 (need = 43); last_template_height=43 (need > valid sync current)' ;;
    zero-current) expected='last_state=done (need done); last_connected=true (need true); last_sync_current=0 (need positive integer); last_template_updated=1 (need >= 1); last_receipt_state=READY (need READY); last_receipt_height=43 (need = 43); last_template_height=43 (need > 0)' ;;
    *) expected='' ;;
    esac
    if [ -n "$expected" ] && [ "$TEMPLATE_FAILURE" != "$expected" ]; then
        printf '%s: unexpected template failure: %s\n' "$CASE" "$TEMPLATE_FAILURE"
        bad=$((bad + 1))
    fi
    [ "$PHASE" = 3 ] || bad=$((bad + 1))
    [ "$(head -n 1 "$OUT_DIR/tari-enable/snapshots.log")" = height_before=42 ] || bad=$((bad + 1))
    [ "$(grep -cx 'height_before=42' "$OUT_DIR/tari-enable/snapshots.log")" = 1 ] || bad=$((bad + 1))
    [ "$(grep -cx 'enable_started=1' "$OUT_DIR/tari-enable/snapshots.log")" = 1 ] || bad=$((bad + 1))
    expected_snapshot_height=44
    [ "$CASE" != same-height ] || expected_snapshot_height=42
    jq -e -s --arg height "$expected_snapshot_height" 'length == 1 and .[0].tari.height == $height' <(sed -n '/^phase=before-off$/,/^phase=after-off$/{ /^{$/,/^}$/p; }' "$OUT_DIR/tari-enable/snapshots.log") >/dev/null || bad=$((bad + 1))
    [ -s "$OUT_DIR/tari-enable/off.apply.log" ] && [ -s "$OUT_DIR/tari-enable/on.apply.log" ] || bad=$((bad + 1))
    grep -q 'phase=after-restore' "$OUT_DIR/tari-enable/snapshots.log" || bad=$((bad + 1))
    if grep -q must-not-be-retained "$OUT_DIR/tari-enable/snapshots.log"; then bad=$((bad + 1)); fi
    if [ -f "$OUT_DIR/tari-enable/samples.jsonl" ] && grep -q must-not-be-retained "$OUT_DIR/tari-enable/samples.jsonl"; then bad=$((bad + 1)); fi
    if [ "$CASE" != recreated ] && [ "$CASE" != stopped ]; then
        jq -e -s 'length > 0 and all(.[]; (.observed | type) == "number" and .observed > 1)' "$OUT_DIR/tari-enable/samples.jsonl" >/dev/null || bad=$((bad + 1))
    fi
    if [ "$CASE" = recreated ] || [ "$CASE" = stopped ]; then
        [ "$CONTINUITY_PASSES" = 0 ] || bad=$((bad + 1))
    else
        [ "$CONTINUITY_PASSES" = 1 ] || bad=$((bad + 1))
    fi
    if [ "$CASE" = unchanged ] || [ "$CASE" = same-height ] || [ "$CASE" = never-syncing ] || [ "$CASE" = loading-to-done ]; then
        [ "$rc:$FAILURE_COUNT" = 0:0 ] || bad=$((bad + 1))
        jq -e -s '.[-1].observed - .[0].observed >= 90' "$OUT_DIR/tari-enable/samples.jsonl" >/dev/null || bad=$((bad + 1))
    else
        [ "$rc" = 1 ] && [ "$FAILURE_COUNT" -gt 0 ] || bad=$((bad + 1))
        [ -s "$OUT_DIR/tari-enable/dashboard.log" ] && [ -s "$OUT_DIR/tari-enable/captured" ] || bad=$((bad + 1))
        if [ "$CASE" != recreated ] && [ "$CASE" != stopped ]; then
            [ -s "$OUT_DIR/tari-enable/samples.jsonl" ] || bad=$((bad + 1))
            jq -e -s 'length > 0 and all(.[]; has("observed") and has("hashes") and has("template_updated") and has("receipt_state") and has("receipt_height") and has("tari_sync") and (has("secret") | not))' "$OUT_DIR/tari-enable/samples.jsonl" >/dev/null || bad=$((bad + 1))
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
