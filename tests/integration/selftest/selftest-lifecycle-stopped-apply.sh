#!/usr/bin/env bash
set -euo pipefail
echo "== mining step over a stopped stack: render-only apply keeps it stopped =="
INTEGRATION_RUN_SUITE=1
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)
work=$(mktemp -d "${TMPDIR:-/tmp}/lifecycle-stopped-apply.XXXXXX")
trap 'rm -rf "$work"' EXIT
(
    source "$ROOT/tests/integration/lib.sh"
    # shellcheck source=tests/integration/lib/run-lifecycle-miners.sh
    source "$ROOT/tests/integration/lib/run-lifecycle-miners.sh"
    LIFECYCLE_MINER_STATE="$work/state.json"
    started=old
    lifecycle_proxy_started() {
        [ ! -e "$work/absent" ] || return 1
        printf '%s' "$started"
    }
    lifecycle_worker_set() { printf '["local"]'; }
    lifecycle_miners_returned() { [ "$started" != old ]; }
    lifecycle_mining_diagnostics() { :; }
    sleep() { SECONDS=$((SECONDS + 601)); }
    remove_proxy() { touch "$work/absent"; }
    render_only() { :; }
    render_fails() { return 7; }
    start_proxy() {
        rm -f "$work/absent"
        started=new
    }
    restart_proxy() {
        rm -f "$work/absent"
        started=restarted
    }
    apply_render_rc=9 apply_restart_rc=9 apply_broken_rc=9
    _run_lifecycle() {
        lifecycle_mining_step down remove_proxy
        [ "$(jq -r .stopped "$LIFECYCLE_MINER_STATE")" = 1 ]
        if lifecycle_mining_step apply render_only; then apply_render_rc=0; else apply_render_rc=$?; fi
        [ "$(jq -r .stopped "$LIFECYCLE_MINER_STATE")" = 1 ]
        lifecycle_mining_step up start_proxy
        [ "$(jq -r .stopped "$LIFECYCLE_MINER_STATE")" = 0 ]
        started=old
        lifecycle_mining_step down remove_proxy
        if lifecycle_mining_step apply restart_proxy; then apply_restart_rc=0; else apply_restart_rc=$?; fi
        [ "$(jq -r .stopped "$LIFECYCLE_MINER_STATE")" = 0 ]
        started=old
        lifecycle_mining_step down remove_proxy
        if lifecycle_mining_step apply render_fails; then apply_broken_rc=0; else apply_broken_rc=$?; fi
        [ "$apply_broken_rc" = 7 ]
        lifecycle_mining_step up start_proxy
        return 0
    }
    run_lifecycle >"$work/row-output"
    [ "$apply_render_rc" = 0 ]
    [ "$apply_restart_rc" = 0 ]
    [ "$IT_FAIL" = 0 ]
    [ "$IT_PASS" = 3 ]
    if grep -Fq 'apply proxy restarts' "$work/row-output"; then exit 1; fi
    grep -Fq 'apply workers reconnect and accept post-restart shares (#3375)' "$work/row-output"
    grep -Fq 'up workers reconnect and accept post-restart shares (#3375)' "$work/row-output"
)
printf '%s\n' 'PASS: a render-only apply on a stopped stack stays silent and stopped, a restarting apply is verified, a failing apply keeps its own verdict'
