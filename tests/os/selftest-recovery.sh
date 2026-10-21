#!/usr/bin/env bash
# shellcheck disable=SC2034
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OS_RUN_SUITE=1
source "$HERE/lib/recovery-invariants.sh"
head_sha=$(printf '%040d' 1)
snapshot=$(
    cat <<JSON
B|recovery|$head_sha
A_OK=1
A_TRY=0
B_OK=1
B_TRY=0
ORDER=B A
{"booted":"B","boot_primary":"rootfs.1","slots":[{"rootfs.0":{"boot_status":"good"}},{"rootfs.1":{"boot_status":"good"}}]}
JSON
)
recovery_slot_matches "$snapshot" B recovery "$head_sha"
for change in 'B|recovery|/B|previous|' 'A_OK=1/A_OK=0' 'A_TRY=0/A_TRY=1' 'B_OK=1/B_OK=0' 'B_TRY=0/B_TRY=1' 'ORDER=B A/ORDER=A B' 'rootfs.1/rootfs.0' 'good/bad'; do
    mutant=${snapshot/"${change%%/*}"/"${change#*/}"}
    if recovery_slot_matches "$mutant" B recovery "$head_sha"; then
        printf 'FAIL: slot invariant accepted %s\n' "$change" >&2
        exit 1
    fi
done
! recovery_slot_matches "$snapshot" B recovery "$(printf '%040d' 2)"
! recovery_slot_matches '' B recovery "$head_sha"
unmarked=${snapshot/B|recovery|/B||}
recovery_slot_matches "$unmarked" B '' "$head_sha"
! recovery_slot_matches "$unmarked" B '' "$(printf '%040d' 2)"
! recovery_slot_matches "${snapshot%%\{*}{invalid}" B recovery "$head_sha"
a=$(printf '%064d' 1) b=$(printf '%064d' 2) c=$(printf '%064d' 3)
recovery_ids_disjoint "$a" "$b"
recovery_ids_disjoint "$a" ''
! recovery_ids_disjoint "$a" "$a"
! recovery_ids_disjoint "$a" "$b"$'\n'"$a"
! recovery_ids_disjoint '' "$b"
! recovery_ids_disjoint error "$b"
! recovery_ids_disjoint "$a" error
recovery_ids_disjoint "$a"$'\n'"$b" "$c"
identity=$(printf '%064d\n%064d' 1 2)
recovery_identity_matches "$identity" "$identity"
! recovery_identity_matches "$identity" "$(printf '%064d\n%064d' 1 3)"
! recovery_identity_matches '' ''
! recovery_identity_matches invalid invalid
! recovery_identity_matches "$a" "$a"
(
    fingerprint_dir=$(mktemp -d)
    trap 'rm -rf "$fingerprint_dir"' EXIT
    printf '{"dashboard":{"check_for_updates":true},"xvb":{"enabled":true}}' >"$fingerprint_dir/config.json"
    printf 'TARI_WALLET_PASSWORD=fixture-first\nPROXY_AUTH_TOKEN=fixture\n' >"$fingerprint_dir/.env"
    _ssh() {
        local command="$1" target
        printf -v target 'cd %q' "$fingerprint_dir"
        bash -c "${command/cd \/data\/pithead/$target}"
    }
    original=$(_recovery_identity)
    recovery_identity_matches "$original" "$original"
    printf '{"dashboard":{"check_for_updates":false},"xvb":{"enabled":true}}' >"$fingerprint_dir/config.json"
    ! recovery_identity_matches "$original" "$(_recovery_identity)"
    printf '{"dashboard":{"check_for_updates":true},"xvb":{"enabled":true}}' >"$fingerprint_dir/config.json"
    printf 'TARI_WALLET_PASSWORD=fixture-changed\nPROXY_AUTH_TOKEN=fixture\n' >"$fingerprint_dir/.env"
    ! recovery_identity_matches "$original" "$(_recovery_identity)"
)
for fault in none reboot-1 reboot-2 commit-1 commit-2; do
    (
        RECOVERY_HEAD=$head_sha
        reboots=0 commits=0 passes=0 failures=0
        _reboot_wait() {
            reboots=$((reboots + 1))
            [ "$fault" != "reboot-$reboots" ]
        }
        _recovery_wait_slot() {
            commits=$((commits + 1))
            [ "$fault" != "commit-$commits" ]
        }
        ok() { passes=$((passes + 1)); }
        bad() { failures=$((failures + 1)); }
        if [ "$fault" = none ]; then
            _slot_invariant_reboot fixture
            [ "$reboots,$commits,$passes,$failures" = 2,2,1,0 ]
        else
            ! _slot_invariant_reboot fixture
            [ "$passes:$failures" = 0:1 ]
        fi
    )
done
echo 'recovery invariants: PASS (slot/source/TRY/fallback controls, census controls, two observed reboots)'
