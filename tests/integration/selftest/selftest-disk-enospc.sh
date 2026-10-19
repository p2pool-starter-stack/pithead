#!/usr/bin/env bash
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$HERE/../lib.sh"
# shellcheck disable=SC2034
INTEGRATION_RUN_SUITE=1
source "$HERE/../lib/run-faults.sh"

drive_disk_fault() (
    local fault="$1" mounted=0
    IT_FAIL=0 IT_PASS=0
    env_on_box() { [ "$fault" = no-dir ] || printf '/fixture/data'; }
    rx() {
        case "$1" in
        'sudo mount '*)
            [ "$fault" != mount ] || return 1
            [[ "$1" == *mode=0700* ]] || return 1
            mounted=1
            ;;
        'LC_ALL=C sudo -n dd'*)
            [[ "$1" == *oflag=excl,nofollow* ]] || return 1
            if [ "$fault" = no-enospc ]; then printf 'Permission denied' >&2; else printf 'No space left on device' >&2; fi
            return 1
            ;;
        'sudo umount '*) mounted=0 ;;
        'docker compose restart dashboard') : ;;
        *) return 127 ;;
        esac
    }
    wait_for() {
        shift 3
        local attempt
        for attempt in 1 2 3; do "$@" && return 0; done
        return 1
    }
    api_state() {
        if [ "$fault" = delayed ] && [ "${attempt:-0}" -gt 0 ] && [ "$attempt" -lt 3 ]; then
            printf '{}'
            return
        fi
        case "$fault" in
        empty) return 1 ;;
        malformed)
            printf 'not json'
            return
            ;;
        esac
        if [ "$mounted" = 1 ]; then
            case "$fault" in
            no-badge) printf '{"db_healthy":false,"badges":[],"system":{"disk":{"percent":"100.0%%"}}}' ;;
            warn) printf '{"db_healthy":false,"badges":[{"text":"Disk 100%% full","variant":"warn"}],"system":{"disk":{"percent":"100.0%%"}}}' ;;
            low) printf '{"db_healthy":false,"badges":[{"text":"⚠ Disk 100%% full","variant":"bad"}],"system":{"disk":{"percent":"20.0%%"}}}' ;;
            *) printf '{"db_healthy":false,"badges":[{"text":"⚠ Disk 100%% full","variant":"bad"}],"system":{"disk":{"percent":"100.0%%"}}}' ;;
            esac
        else
            case "$fault" in
            stale) printf '{"db_healthy":true,"badges":[{"text":"⚠ Disk 100%% full","variant":"bad"}],"system":{"disk":{"percent":"20.0%%"}}}' ;;
            missing) printf '{"db_healthy":true}' ;;
            *) printf '{"db_healthy":true,"badges":[],"system":{"disk":{"percent":"20.0%%"}}}' ;;
            esac
        fi
    }
    fault_disk_enospc
    [ "$mounted" = 0 ] || it_fail "tmpfs removed" "still mounted"
    printf '\nresult: %s\n' "$IT_FAIL"
)

out=$(drive_disk_fault healthy)
assert_contains "full disk has a badge row" "$out" 'critical disk badge under real ENOSPC'
assert_contains "recovery has a badge row" "$out" 'disk badge clears after real disk restored'
assert_contains "healthy fault and recovery pass" "$out" 'result: 0'
assert_contains "badge observations can settle during polling" "$(drive_disk_fault delayed)" 'result: 0'
for fault in no-badge warn low empty malformed stale missing no-dir mount no-enospc; do
    out=$(drive_disk_fault "$fault")
    if grep -q 'result: 0$' <<<"$out"; then
        it_fail "$fault cannot pass the disk fault" "$out"
    else
        it_pass "$fault cannot pass the disk fault"
    fi
done
printf '\nselftest-disk-enospc: %s passed, %s failed\n' "$IT_PASS" "$IT_FAIL"
[ "$IT_FAIL" -eq 0 ]
