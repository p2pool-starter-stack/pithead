#!/usr/bin/env bash
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$HERE/../lib.sh"
source "$HERE/../e2e-sync-sample.sh"
WAIT_SRC="$(sed -n '/^wait_synced() {/,/^}$/p' "$HERE/../e2e.sh")"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

run_case() (
    local mode="$1" rc=0
    printf '0\n' >"$WORK/clock"
    printf '0\n' >"$WORK/inspect"
    date() {
        if [ "$1" = -d ]; then printf '90\n'; else printf '%s\n' "$((100 + $(cat "$WORK/clock")))"; fi
    }
    sleep() { printf '%s\n' "$(($(cat "$WORK/clock") + $1))" >"$WORK/clock"; }
    timeout() {
        shift
        "$@"
    }
    docker() {
        local n
        n="$(($(cat "$WORK/inspect") + 1))"
        printf '%s\n' "$n" >"$WORK/inspect"
        if [ "$mode" = restart ] && [ "$((n % 2))" = 0 ]; then printf 'new 90\n'; else printf 'old 90\n'; fi
    }
    curl() {
        local tick
        tick="$(cat "$WORK/clock")"
        case "${*: -1}" in
        */metrics)
            case "$mode" in
            missing) return 0 ;;
            duplicate) printf 'pithead_snapshot_age_seconds 0.25\npithead_snapshot_age_seconds 0.25\n' ;;
            large-metrics) head -c 65537 /dev/zero | tr '\0' x ;;
            unreadable) return 22 ;;
            partial)
                printf 'pithead_snapshot_age_seconds 0.25\n'
                return 18
                ;;
            malformed) printf 'pithead_snapshot_age_seconds NaN\n' ;;
            equal) printf 'pithead_snapshot_age_seconds %s\n' "$((10 + tick))" ;;
            stale) printf 'pithead_snapshot_age_seconds %s\n' "$((50 + tick))" ;;
            delayed)
                if [ "$tick" -lt 16 ]; then printf 'pithead_snapshot_age_seconds %s\n' "$((50 + tick))"; else printf 'pithead_snapshot_age_seconds 0.25\n'; fi
                ;;
            *) printf 'pithead_snapshot_age_seconds 2.5e-1\n' ;;
            esac
            ;;
        */api/state)
            case "$mode" in
            forged)
                printf '{"sync":{"monero":{"state":"done"},"tari":{"state":"done live\\nignored"}}}\n'
                return
                ;;
            large-state)
                head -c 1048577 /dev/zero | tr '\0' x
                return
                ;;
            duplicate-state)
                printf '{"sync":{"monero":{"state":"done"},"tari":{"state":"done"}}}\n%.0s' 1 2
                return
                ;;
            esac
            if [ "$mode" = delayed ] && [ "$tick" = 16 ]; then
                printf '{"sync":{"monero":{"state":"done"},"tari":{"state":"syncing"}}}\n'
            else
                printf '{"sync":{"monero":{"state":"done"},"tari":{"state":"done"}}}\n'
            fi
            ;;
        *) return 1 ;;
        esac
    }
    on_bench() (eval "$1")
    ok() { :; }
    warn() { :; }
    eval "$WAIT_SRC"
    wait_synced 24 preflight >/dev/null 2>&1 || rc=$?
    printf '%s|%s' "$rc" "$(cat "$WORK/clock")"
)

echo "== recreated dashboard sync freshness (#2652) =="
assert_eq "#2652 restored done/done waits through two stale polls and the first live syncing poll" "$(run_case delayed)" '0|24'
assert_eq "#2652 a live done/done snapshot passes immediately" "$(run_case live)" '0|0'
for mode in stale missing unreadable partial malformed equal restart duplicate large-metrics forged large-state duplicate-state; do
    assert_eq "#2652 $mode freshness cannot authorize readiness" "$(run_case "$mode")" '1|24'
done

printf '\npassed: %s, failed: %s\n' "$IT_PASS" "$IT_FAIL"
[ "$IT_FAIL" -eq 0 ]
