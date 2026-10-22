#!/usr/bin/env bash
# shellcheck disable=SC2034
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OS_RUN_SUITE=1 SCRIPT_DIR="$HERE"
source "$HERE/phases/recovery.sh"
scratch=$(mktemp -d)
trap 'rm -rf "$scratch"' EXIT
SERIAL="$scratch/serial"
: >"$SERIAL"

for marker in absent present; do
    for fault in none boot ssh provision health source; do
        (
            PITHEAD_OLD_IMAGE="$scratch/old-image"
            PITHEAD_OLD_IMAGE_COMMIT=$(printf '%040d' 2)
            RECOVERY_HEAD=$(printf '%040d' 1)
            : >"$PITHEAD_OLD_IMAGE"
            marker_file="$scratch/marker-$marker"
            [ "$marker" != present ] || printf previous >"$marker_file"
            ok() { :; }
            bad() { printf '%s\n' "$*"; }
            _vm_boot_disk() { [ "$fault" != boot ]; }
            _wait_ssh() { [ "$fault" != ssh ]; }
            _wizard_provision_capture() { [ "$fault" != provision ]; }
            _reset_slot_good_stack() { [ "$fault" != health ]; }
            _ssh() {
                case "$*" in
                *BUILD_COMMIT*)
                    if [ "$fault" = source ]; then printf '%s' "$RECOVERY_HEAD"; else printf '%s' "$PITHEAD_OLD_IMAGE_COMMIT"; fi
                    ;;
                *pithead-test-marker*)
                    local command="$*"
                    command="${command//\/etc\/pithead-test-marker/$marker_file}"
                    bash -c "$command"
                    ;;
                *os-update*) return 0 ;;
                *) return 127 ;;
                esac
            }
            _reboot_wait() { :; }
            _recovery_wait_slot() {
                if [ "$1" = A ]; then
                    [ "$3" = "$PITHEAD_OLD_IMAGE_COMMIT" ] || return 1
                    if [ "$marker" = absent ]; then [ -z "$2" ]; else [ "$2" = previous ]; fi
                else
                    [ "$2" = recovery ] && [ "$3" = "$RECOVERY_HEAD" ]
                fi
            }
            _build_bundle() { printf bundle; }
            _stage_bundle() { :; }
            _recovery_fallback_intact() { :; }
            if [ "$fault" = none ]; then
                _recovery_prepare
            else
                if output=$(_recovery_prepare); then
                    printf 'FAIL: fixture accepted %s\n' "$fault" >&2
                    exit 1
                fi
                case "$fault" in
                boot) expected='previous-release boot' ;;
                ssh) expected='previous-release SSH' ;;
                provision) expected='previous-release provisioning' ;;
                health) expected='previous-release health' ;;
                source) expected='previous-release source identity' ;;
                esac
                [[ "$output" == *"$expected failed"* ]]
            fi
        )
    done
done

for fault in none reset page sentinel-monero sentinel-tari old-container unreadable-census setup health reboot fallback identity; do
    (
        passes=0 failures=0 changed=no
        RECOVERY_HEAD=$(printf '%040d' 1)
        expected_identity=$(printf '%064d\n%064d' 1 2)
        ok() { passes=$((passes + 1)); }
        bad() { failures=$((failures + 1)); }
        sleep() { SECONDS=$((SECONDS + $1)); }
        _recovery_wait_slot() { :; }
        _recovery_identity() {
            if [ "$changed:$fault" = yes:identity ]; then printf '%064d\n%064d' 1 3; else printf '%s' "$expected_identity"; fi
        }
        _recovery_chain_sentinels() { printf '/data/monero\n/data/tari\n'; }
        _recovery_project_ids() {
            [ "$changed:$fault" != yes:unreadable-census ] || return 125
            if [ "$changed" = yes ] && [ "$fault" != old-container ]; then printf '%064d' 2; else printf '%064d' 1; fi
        }
        _reboot_wait() {
            [ "$fault" != reset ] || return 1
            changed=yes
        }
        _wait_setup_page() { [ "$fault" != page ]; }
        _ssh() {
            case "$1" in
            *'/data/monero/.recovery-matrix-sentinel'*) [ "$fault" != sentinel-monero ] ;;
            *'/data/tari/.recovery-matrix-sentinel'*) [ "$fault" != sentinel-tari ] ;;
            *) return 127 ;;
            esac
        }
        _wizard_provision_capture() { [ "$fault" != setup ]; }
        _reset_slot_good_stack() { [ "$fault" != health ]; }
        _recovery_dashboard_ready() { [ "$fault" != health ]; }
        _slot_invariant_reboot() { [ "$fault" != reboot ]; }
        _recovery_fallback_intact() { [ "$fault" != fallback ]; }
        if [ "$fault" = none ]; then
            _recovery_config_reset
            [ "$passes:$failures" = 11:0 ]
        elif _recovery_config_reset; then
            printf 'FAIL: config-reset -> wizard-setup accepted %s\n' "$fault" >&2
            exit 1
        fi
    )
done
printf 'focused recovery flows: PASS\n'
