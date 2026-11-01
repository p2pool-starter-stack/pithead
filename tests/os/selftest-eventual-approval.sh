#!/usr/bin/env bash
set -euo pipefail
HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
source "$HERE/provision-browser-submit.sh"
source "$HERE/appliance-config-approval-leg.sh"
source "$HERE/../integration/lib/selftest/fake-eventual.sh"
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
msg='Dashboard login password CHANGED: a mistake locks this session out and changes the console root login.'
preview=$(jq -nc --arg msg "$msg" '{id:"r1",status:"previewed",approval_required:true,changes:[{msg:$msg}]}')
sensitive_live_config() { printf '{"dashboard":{"auth":{"password":"fixture"}}}'; }
sensitive_preview() { export APPROVAL_PREVIEW=$preview APPROVAL_REQUEST_ID=r1; }
dashboard_control_request() { return 1; }
bad() { failure=$1; }
sleep() { sleeps=$((sleeps + 1)); }
_ssh() { fake_eventual "$work/reads" "$mode" 3 "{\"id\":\"r1\",\"status\":\"$inflight\"}" '{"id":"r1","status":"applied"}'; }

for inflight in previewed pending accepted running; do
    for mode in after never flapping; do
        printf '0\n' >"$work/reads"
        sleeps=0 failure='' rc=0
        password_commit_via_host fixture-new-password || rc=$?
        reads=$(cat "$work/reads")
        case "$mode" in
        after) expected_rc=0 expected_reads=4 expected_sleeps=3 ;;
        flapping) expected_rc=0 expected_reads=2 expected_sleeps=1 ;;
        never)
            expected_rc=1 expected_reads=140 expected_sleeps=140
            [[ "$failure" == *"status=$inflight"* ]] || {
                printf 'FAIL: approval %s %s missing final status\n' "$inflight" "$mode" >&2
                exit 1
            }
            ;;
        esac
        if [ "$rc" != "$expected_rc" ] || [ "$reads" != "$expected_reads" ] || [ "$sleeps" != "$expected_sleeps" ] ||
            { [ "$expected_rc" = 0 ] && [ -n "$failure" ]; }; then
            printf 'FAIL: approval %s %s rc=%s reads=%s sleeps=%s\n' "$inflight" "$mode" "$rc" "$reads" "$sleeps" >&2
            exit 1
        fi
        printf 'PASS: approval %s %s\n' "$inflight" "$mode"
    done
done
