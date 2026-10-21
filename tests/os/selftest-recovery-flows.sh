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

for operation in config-reset factory-reset; do
    for route in wizard-setup wizard-restore cli-restore; do
        for fault in none reset page sentinel-monero sentinel-tari old-container setup health reboot fallback identity; do
            (
                passes=0 failures=0 changed=no
                RECOVERY_HEAD=$(printf '%040d' 1)
                RECOVERY_ARCHIVE="$scratch/archive"
                KEY="$scratch/key" ip=guest.invalid
                ok() { passes=$((passes + 1)); }
                bad() { failures=$((failures + 1)); }
                sleep() { SECONDS=$((SECONDS + 5)); }
                _recovery_wait_slot() { :; }
                expected_identity=$(printf '%064d\n%064d' 1 2)
                RECOVERY_IDENTITY=$expected_identity
                _recovery_backup() { :; }
                _recovery_identity() {
                    if [ "$fault" = identity ]; then printf '%064d\n%064d' 1 3; else printf '%s' "$expected_identity"; fi
                }
                _recovery_chain_sentinels() { printf '/data/monero\n/data/tari\n'; }
                _recovery_project_ids() {
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
                    *' restore -y '*) [ "$fault" != setup ] ;;
                    *) return 0 ;;
                    esac
                }
                _wizard_provision_capture() { [ "$fault" != setup ]; }
                _recovery_wizard_restore() { [ "$fault" != setup ]; }
                timeout() { :; }
                _reset_slot_good_stack() { [ "$fault" != health ]; }
                _recovery_dashboard_ready() { [ "$fault" != health ]; }
                _slot_invariant_reboot() { [ "$fault" != reboot ]; }
                _recovery_fallback_intact() { [ "$fault" != fallback ]; }
                if [ "$fault" = identity ] && [ "$route" = wizard-setup ]; then exit 0; fi
                if [ "$fault" = none ]; then
                    _recovery_reset_cell "$operation" "$route"
                    expected_passes=6
                    [ "$route" = wizard-setup ] || expected_passes=7
                    [ "$passes:$failures" = "$expected_passes:0" ]
                elif _recovery_reset_cell "$operation" "$route"; then
                    printf 'FAIL: %s -> %s accepted %s\n' "$operation" "$route" "$fault" >&2
                    exit 1
                fi
            )
        done
    done
done

for route in keep wizard-setup wizard-restore; do
    for fault in none saved boot submit health config identity reboot fallback ignored; do
        (
            [ "$fault" != ignored ] || [ "$route" = wizard-setup ] || exit 0
            [ "$fault:$route" != config:wizard-setup ] || exit 0
            [ "$fault:$route" != config:wizard-restore ] || exit 0
            [ "$fault:$route" != identity:keep ] || exit 0
            [ "$fault:$route" != identity:wizard-setup ] || exit 0
            RECOVERY_HEAD=$(printf '%040d' 1)
            expected_identity=$(printf '%064d\n%064d' 1 2)
            RECOVERY_IDENTITY=$expected_identity
            SA_SPOOL=/data/pithead/data/firstboot
            SA_SERIAL_OFFSET=0
            ip=guest.invalid submitted=no
            _recovery_wait_slot() { :; }
            _recovery_backup() { :; }
            _setup_again_boot() { [ "$fault" != boot ]; }
            _setup_again_session() { jar="$scratch/jar"; }
            _ssh() {
                case "$1" in
                *saved-role.json*)
                    if [ "$fault" = saved ]; then printf '{"role":"rig"}'; else printf '{"role":"pithead"}'; fi
                    ;;
                jq*) [ "$fault" != ignored ] ;;
                'sha256sum '*)
                    if [ "$submitted" = yes ] && [ "$fault" = config ]; then printf changed; else printf original; fi
                    ;;
                *) return 127 ;;
                esac
            }
            curl() {
                submitted=yes
                [ "$fault" != submit ] || return 1
                [[ "$*" != *'/submit '* ]] || printf 200
            }
            wizard_state_poll() { WIZ_STATE='{}'; }
            provision_browser_config() { printf '%s' "$1"; }
            provision_browser_submit() { if [ "$fault" != submit ]; then printf 200; else printf 400; fi; }
            _recovery_handoff() { [ "$fault" != submit ]; }
            _recovery_wizard_restore() { [ "$fault" != submit ]; }
            _recovery_identity() {
                if [ "$fault" = identity ]; then printf '%064d\n%064d' 1 3; else printf '%s' "$expected_identity"; fi
            }
            _reset_slot_good_stack() { [ "$fault" != health ]; }
            _recovery_dashboard_ready() { [ "$fault" != health ]; }
            _slot_invariant_reboot() { [ "$fault" != reboot ]; }
            _recovery_fallback_intact() { [ "$fault" != fallback ]; }
            ok() { :; }
            bad() { :; }
            if [ "$fault" = none ]; then
                _recovery_saved_setup "$route"
            elif _recovery_saved_setup "$route"; then
                printf 'FAIL: Set up again -> %s accepted %s\n' "$route" "$fault" >&2
                exit 1
            fi
        )
    done
done

for fault in none missing-card bad-card ack; do
    (
        source "$HERE/recovery-wizard.sh"
        SECONDS=0 ip=guest.invalid
        sleep() { SECONDS=$((SECONDS + 5)); }
        _ssh() { :; }
        provisioning_settled() { :; }
        provisioning_setup_failed() { return 1; }
        curl() {
            case "$*" in
            *'/api/handoff'*)
                case "$fault" in
                missing-card) printf '{}' ;;
                bad-card) printf '{"password":true,"username":{}}' ;;
                *) printf '{"password":"fixture","username":"fixture"}' ;;
                esac
                ;;
            *'/handoff-ack'*) [ "$fault" != ack ] ;;
            *) return 127 ;;
            esac
        }
        if [ "$fault" = none ]; then
            _recovery_handoff "$scratch/jar"
        elif _recovery_handoff "$scratch/jar"; then
            printf 'FAIL: handoff accepted %s\n' "$fault" >&2
            exit 1
        fi
    )
done

for fault in none wizard caddy code body churn transport; do
    (
        source "$HERE/recovery-wizard.sh"
        SECONDS=0 ip=guest.invalid
        sleep() { SECONDS=$((SECONDS + 5)); }
        _ssh() {
            case "$1" in
            *'test '*caddy*) [ "$fault" != wizard ] && [ "$fault" != caddy ] ;;
            *'inspect caddy'*)
                if [ "$fault" = churn ]; then printf 'caddy %s start' "$SECONDS"; else printf 'caddy 0 start'; fi
                ;;
            *) return 127 ;;
            esac
        }
        curl() {
            [ "$fault" != transport ] || return 1
            if [ "$fault" = body ]; then
                printf 'Pithead setup\n401'
            elif [ "$fault" = code ]; then
                printf 'dashboard\n503'
            else printf 'dashboard\n401'; fi
        }
        if [ "$fault" = none ]; then
            _recovery_dashboard_ready
            [ "$SECONDS" -ge 60 ]
        elif _recovery_dashboard_ready; then
            printf 'FAIL: dashboard ownership accepted %s\n' "$fault" >&2
            exit 1
        fi
    )
done
echo 'recovery flows: PASS (six cells, independent failure controls, sustained dashboard ownership)'
