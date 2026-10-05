#!/usr/bin/env bash
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=tests/os/restore-live-state-verdict.sh
source "$HERE/restore-live-state-verdict.sh"
scratch=$(mktemp -d)
trap 'rm -rf "$scratch"' EXIT
sleep() {
    printf '%s\n' "$1" >>"$scratch/sleeps"
    [ "$mode" != sleep-fails ]
}
_ssh() {
    printf '%s\n' "$1" >>"$scratch/commands"
    case "$1" in
    "podman stop dashboard"*) [ "$mode" != stop-fails ] ;;
    "podman start p2pool"*) [ "$mode" != start-fails ] ;;
    "podman stop p2pool"*) [ "$mode" != cleanup-fails ] ;;
    "podman inspect"*)
        local sample
        sample=$(cat "$scratch/sample")
        printf '%s\n' "$((sample + 1))" >"$scratch/sample"
        case "$mode:$sample" in
        unreadable:*) return 1 ;;
        crash-before:0) echo 'container false 139 0' ;;
        restarted-before:0) echo 'container true 0 130' ;;
        crash-during:3) echo 'container false 139 1' ;;
        restarted-during:3) echo 'container true 0 1' ;;
        replaced:3) echo 'replacement true 0 0' ;;
        stopped:3) echo 'container false 0 0' ;;
        malformed:*) echo 'container true 0 0 unexpected' ;;
        *:0) echo 'container false 0 0' ;;
        *) echo 'container true 0 0' ;;
        esac
        ;;
    "podman logs"*) echo 'bounded failure diagnostics' ;;
    *) return 1 ;;
    esac
}
for mode in clean sleep-fails stop-fails start-fails cleanup-fails unreadable crash-before restarted-before crash-during restarted-during replaced stopped malformed; do
    printf '0\n' >"$scratch/sample"
    : >"$scratch/commands"
    : >"$scratch/sleeps"
    if restore_p2pool_startup >"$scratch/out" 2>"$scratch/err"; then
        [ "$mode" = clean ] || {
            echo "false pass: $mode"
            exit 1
        }
        [ "$(cat "$scratch/sample")" = 5 ]
        [ "$(wc -l <"$scratch/sleeps" | tr -d ' ')" = 3 ]
    else
        [ "$mode" != clean ] || {
            cat "$scratch/err"
            exit 1
        }
        grep -Fq 'bounded failure diagnostics' "$scratch/err"
        grep -Fq 'journalctl -k -b -n 200 --no-pager' "$scratch/commands"
    fi
    grep -Fq 'podman stop p2pool >/dev/null; stopped=$?; podman start dashboard >/dev/null && test "$stopped" -eq 0' "$scratch/commands"
    [ "$(grep -c '^podman start p2pool' "$scratch/commands" || true)" -le 1 ]
done
# Old dashboard logs must not prove a new controller start has re-established its hold.
# shellcheck disable=SC2034 # the sourced harness reads this guard.
OS_RUN_SUITE=1
# shellcheck source=tests/os/restore-fixture-fingerprints.sh
source "$HERE/restore-fixture-fingerprints.sh"
ok() { :; }
bad() { printf '%s\n' "$1" >>"$scratch/gate-failures"; }
_ssh() {
    case "$1" in
    *".Mounts"*) echo /data/dashboard ;;
    *"test -f"*) return 0 ;;
    *".State.StartedAt"*)
        [ "$mode" != unreadable-start ] || return 1
        echo 2026-10-05T07:00:00.000000000Z
        ;;
    "podman logs --since '2026-10-05T07:00:00.000000000Z' dashboard"*) [ "$mode" = fresh-hold ] ;;
    "podman logs dashboard"*) return 0 ;; # a retained pre-restart hold is present
    *) return 1 ;;
    esac
}
for mode in fresh-hold old-hold unreadable-start; do
    : >"$scratch/gate-failures"
    restore_sync_gate_verdict fixture || true
    if [ "$mode" = fresh-hold ]; then
        [ ! -s "$scratch/gate-failures" ]
    else
        [ -s "$scratch/gate-failures" ]
    fi
done
echo 'restore P2Pool startup window, crash detection and controller restoration: PASS'
