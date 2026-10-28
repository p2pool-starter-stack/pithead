#!/usr/bin/env bash
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$HERE/../lib.sh"
INTEGRATION_RUN_SUITE=1 source "$HERE/../lib/run-tari-background-sync.sh"

fixture="$(mktemp -d "${TMPDIR:-${RUNNER_TEMP:?}}/tari-mode-selftest.XXXXXX")"
trap 'rm -rf "$fixture"' EXIT
bad=0
for mode_case in remote local off empty unknown unreadable unreadable-remote unreadable-local; do
    IT_PASS=0 IT_FAIL=0 IT_SKIPPED_LEGS=0 IT_SKIPPED_BY_DESIGN=0 IT_SKIPPED_MISSING=0 IT_SKIPPED_COVERED=0 IT_SKIPPED_NAMES=""
    env_on_box() {
        [ "$1" = TARI_MODE ] || return 1
        case "$mode_case" in
        remote | local | off) printf '%s\n' "$mode_case" ;;
        empty) return 0 ;;
        unknown) printf 'unexpected\n' ;;
        unreadable) return 1 ;;
        unreadable-remote)
            printf 'remote\n'
            return 1
            ;;
        unreadable-local)
            printf 'local\n'
            return 1
            ;;
        esac
    }
    api_state() {
        printf 'api\n' >>"$fixture/probes"
        printf '{}\n'
    }
    rx() {
        printf 'transport\n' >>"$fixture/mutations"
        return 1
    }
    push_config() {
        printf 'config\n' >>"$fixture/mutations"
        return 1
    }
    pithead() {
        printf 'apply\n' >>"$fixture/mutations"
        return 1
    }
    rm -f "$fixture/probes" "$fixture/mutations"
    rc=0
    run_tari_background_sync || rc=$?
    actual="$rc:$IT_PASS:$IT_FAIL:$IT_SKIPPED_LEGS:$IT_SKIPPED_BY_DESIGN:$IT_SKIPPED_MISSING:$IT_SKIPPED_COVERED"
    case "$mode_case" in
    remote) expected=0:0:0:1:1:0:0 ;;
    local) expected=1:0:1:0:0:0:0 ;;
    *) expected=0:0:0:1:0:1:0 ;;
    esac
    if [ "$actual" != "$expected" ]; then
        printf '%s: expected %s, got %s\n' "$mode_case" "$expected" "$actual"
        bad=$((bad + 1))
    fi
    if [ "$mode_case" = local ]; then
        [ -s "$fixture/probes" ] || bad=$((bad + 1))
    else
        [ ! -e "$fixture/probes" ] || bad=$((bad + 1))
        [[ "$IT_SKIPPED_NAMES" == *'Tari-only apply keeps Monero mining (#3094)'* ]] || bad=$((bad + 1))
        [[ "$IT_SKIPPED_NAMES" == *'requires a local Tari baseline'* ]] || bad=$((bad + 1))
    fi
    [ ! -e "$fixture/mutations" ] || bad=$((bad + 1))
done
printf 'Tari background mode selftest: %s failed assertions\n' "$bad"
[ "$bad" = 0 ]
