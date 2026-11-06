#!/usr/bin/env bash
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT=$(mktemp -d) || exit $?
export OS_RUN_SUITE=1
SCRIPT_DIR="$HERE"
# shellcheck source=tests/os/phases/media.sh
source "${1:-$HERE/phases/media.sh}" || exit $?
for scenario in ready delayed absent loop format mount write unmount detach ownership foreign-mount mount-timeout mount-probe; do
    (
        CASE="$ROOT/$scenario"
        mkdir "$CASE"
        TRACE="$CASE/trace"
        : >"$TRACE"
        sleeps=0
        timeout() {
            [ "$1" = -k ] && [ "$2" = 5 ] && [ "$3" = 10 ] || exit 93
            shift 3
            printf 'bounded %s\n' "$1" >>"$TRACE"
            "$@"
        }
        truncate() { : >"${@: -1}"; }
        sgdisk() { return 0; }
        losetup() {
            case "$1" in
            -Pf)
                [ "$scenario" != loop ] || return 1
                printf '%s' "$3" >"$CASE/backing"
                case "$scenario" in absent | delayed) ;; *) touch "$CASE/loopp1" ;; esac
                printf '%s\n' "$CASE/loop"
                ;;
            --list)
                if [ "$scenario" = ownership ]; then printf 'foreign\n'; else cat "$CASE/backing"; fi
                ;;
            -d)
                echo detach >>"$TRACE"
                [ "$scenario" != detach ]
                ;;
            *) exit 91 ;;
            esac
        }
        sleep() {
            sleeps=$((sleeps + 1))
            echo sleep >>"$TRACE"
            if [ "$scenario" = delayed ] && [ "$sleeps" -eq 3 ]; then touch "$CASE/loopp1"; fi
        }
        mkfs.vfat() {
            echo format >>"$TRACE"
            [ "$scenario" != format ]
        }
        mktemp() { command mktemp -d "$CASE/mount.XXXXXX"; }
        mount() {
            echo mount >>"$TRACE"
            [ "$scenario" != mount ] || return 1
            touch "$CASE/mounted"
            if [ "$scenario" = write ]; then mkdir "$2/pithead-config.json"; fi
            [ "$scenario" != mount-timeout ] || return 124
        }
        findmnt() {
            [ "$scenario" != mount-probe ] || return 2
            [ -f "$CASE/mounted" ] || return 1
            if [ "$scenario" = foreign-mount ]; then echo foreign; else echo "$CASE/loopp1"; fi
        }
        umount() {
            echo unmount >>"$TRACE"
            [ "$scenario" != unmount ] || return 1
            if [ -f "$1/pithead-config.json" ]; then
                cmp -s "$1/pithead-config.json" <(printf '%s' '{"p2pool":{"pool":"mini"}}') || exit 92
                command rm "$1/pithead-config.json"
            elif [ -d "$1/pithead-config.json" ]; then
                command rmdir "$1/pithead-config.json"
            fi
        }
        rc=0
        _make_media_stick "$CASE/stick.img" '{"p2pool":{"pool":"mini"}}' >"$CASE/output" 2>&1 || rc=$?
        case "$scenario" in
        ready | delayed) [ "$rc" -eq 0 ] || {
            cat "$CASE/output"
            exit 1
        } ;;
        *)
            [ "$rc" -ne 0 ] || {
                echo "$scenario fixture incorrectly succeeded"
                exit 1
            }
            grep -q 'media fixture failed:' "$CASE/output" || exit 1
            ;;
        esac
        if [ "$scenario" = ready ]; then
            for operation in sgdisk mkfs.vfat mount findmnt umount; do
                [ "$(grep -c "^bounded $operation$" "$TRACE")" -eq 1 ] || exit 1
            done
            [ "$(grep -c '^bounded losetup$' "$TRACE")" -eq 3 ] || exit 1
        fi
        case "$scenario" in
        delayed) [ "$(grep -c '^sleep$' "$TRACE")" -eq 3 ] || exit 1 ;;
        absent)
            [ "$(grep -c '^sleep$' "$TRACE")" -eq 50 ] || exit 1
            ! grep -q '^format$' "$TRACE" || exit 1
            ;;
        format) ! grep -q '^mount$' "$TRACE" || exit 1 ;;
        mount) ! grep -q '^unmount$' "$TRACE" || exit 1 ;;
        unmount | ownership | foreign-mount | mount-probe) ! grep -q '^detach$' "$TRACE" || exit 1 ;;
        esac
        case "$scenario" in
        unmount | ownership | foreign-mount | mount-probe)
            [ -n "$(find "$CASE" -name pithead-config.json -type f -print)" ] || exit 1
            ;;
        esac
        case "$scenario" in
        loop | unmount | ownership | foreign-mount | mount-probe) ;;
        *) grep -q '^detach$' "$TRACE" || exit 1 ;;
        esac
    ) || exit 1
    printf 'PASS fixture %s\n' "$scenario"
done
for failure in construction attachment; do
    for failed_leg in 1 2; do
        (
            TRACE="$ROOT/phase-$failure-$failed_leg"
            : >"$TRACE"
            export ip=guest DISK="$ROOT/guest.img" SERIAL="$ROOT/serial" HARNESS_WALLET=wallet HARNESS_TARI=tari
            calls=0 attachments=0
            info() { :; }
            ok() { printf 'ok %s\n' "$1" >>"$TRACE"; }
            bad() { printf 'bad %s\n' "$1" >>"$TRACE"; }
            _build_image() { echo "$ROOT/guest.img"; }
            losetup() {
                [ "$1" != -d ] || return 0
                echo "$ROOT/initial-loop"
            }
            touch "$ROOT/initial-loopp1"
            mktemp() { command mktemp -d "$ROOT/initial-mount.XXXXXX"; }
            mount() { :; }
            umount() { command rm "$1/pithead-config.json"; }
            sleep() { :; }
            _vm_boot_disk() { :; }
            _wait_ssh() { :; }
            provisioning_settled() { :; }
            provisioning_setup_failed() { return 1; }
            provisioning_state() { echo 'done'; }
            _ssh() {
                case "$1" in
                *'podman ps'*) echo 'dashboard caddy' ;;
                *dashboard.auth.username*) echo admin ;;
                *password*) echo fixture-password ;;
                *p2pool.pool*) echo nano ;;
                *control.enabled* | *auto_heal*) echo true ;;
                reboot) echo reboot >>"$TRACE" ;;
                esac
            }
            _make_media_stick() {
                calls=$((calls + 1))
                [ "$failure" != construction ] || [ "$calls" -ne "$failed_leg" ]
            }
            _attach_media_stick() {
                attachments=$((attachments + 1))
                echo attach >>"$TRACE"
                [ "$failure" != attachment ] || [ "$attachments" -ne "$failed_leg" ]
            }
            _detach_media_stick() { :; }
            _media_stick_has_config() { return 1; }
            wait_serial() { printf 'assert %s\n' "$1" >>"$TRACE"; }
            serial_has() { :; }
            curl() { case "$*" in *-u*) echo 200 ;; *) echo 401 ;; esac }
            phase_media
            grep -q '^bad .*media .*fixture' "$TRACE" || {
                cat "$TRACE"
                exit 1
            }
            expected_attachments=$((failed_leg - 1))
            [ "$failure" != attachment ] || expected_attachments=$failed_leg
            [ "$(grep -c '^attach$' "$TRACE")" -eq "$expected_attachments" ] || exit 1
            [ "$(grep -c '^reboot$' "$TRACE")" -eq "$((failed_leg - 1))" ] || exit 1
            [ "$(grep -c '^assert ' "$TRACE")" -eq "$(((failed_leg - 1) * 2))" ] || exit 1
            [[ "$(tail -1 "$TRACE")" == "bad media "*"fixture "* ]] || exit 1
            ! grep -qi 'cancel' "$TRACE" || exit 1
        ) || exit 1
        printf 'PASS failed %s stops leg %s before reboot and assertions\n' "$failure" "$failed_leg"
    done
done
