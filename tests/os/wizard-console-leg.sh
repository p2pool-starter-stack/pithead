# shellcheck shell=bash
# shellcheck disable=SC2154
wizard_console_details_present() {
    [ -s "$1" ] && grep -Fq "One-time token: $2" "$1" && {
        grep -Fq "https://$3.local" "$1" || grep -Fq "http://$3.local" "$1"
    }
}

wizard_console_record_capture() {
    local label=$1 capture=$2
    [ -f "$capture" ] && [ "$(wc -c <"$capture")" -le 65536 ] || return 1
    printf '\nBEGIN setup-console %s\n' "$label"
    cat "$capture" || return 1
    printf '\nEND setup-console %s\n' "$label"
}

_setup_again_journal_token() {
    local n=0
    SA_JOURNAL_TOKEN=""
    while [ "$n" -lt 40 ]; do
        SA_JOURNAL_TOKEN=$(_ssh "journalctl -b -u pithead-setup-again.service -o cat --no-pager | grep -oE 'One-time token: pit-[A-Z0-9]{6}' | tail -1 | cut -d' ' -f3" 2>/dev/null | tr -d '\r\n')
        [[ "$SA_JOURNAL_TOKEN" =~ ^pit-[A-Z0-9]{6}$ ]] && {
            ok "the current setup-again boot minted and journalled a one-time token"
            return 0
        }
        sleep 3
        n=$((n + 1))
    done
    bad "the current setup-again boot never journalled a one-time token"
    return 1
}

_setup_again_console_race() (
    local mode=$1 prefix=$2 host=$3 offset n=0 ready=0 found=0 started=0
    trap '_ssh "touch /run/pithead-console-race/release && { systemctl stop pithead-console-race.service || systemctl show pithead-console-race.service -p LoadState --value | grep -qx not-found; } && rm -rf /run/pithead-console-race" || exit 1' EXIT
    _ssh 'mkdir -p /run/pithead-console-race && cat >/run/pithead-console-race/writer.sh' <"$SCRIPT_DIR/wizard-console-writer.sh" || return 1
    _ssh "rm -f /run/pithead-console-race/ready /run/pithead-console-race/release /run/issue.d/pithead-setup.issue; systemd-run --quiet --collect --unit=pithead-console-race /bin/bash /run/pithead-console-race/writer.sh $mode" || return 1
    while [ "$n" -lt 30 ]; do
        if _ssh 'test -e /run/pithead-console-race/ready'; then
            ready=1
            break
        fi
        sleep 1
        n=$((n + 1))
    done
    offset=$(stat -c %s "$SERIAL") || return 1
    _ssh 'systemctl show serial-getty@ttyS0.service getty@tty1.service -p Type -p TTYReset -p TTYVHangup' >"$prefix.getty.txt" || return 1
    if [ "$ready" = 1 ] && _ssh 'systemctl restart serial-getty@ttyS0.service getty@tty1.service'; then
        n=0
        while [ "$n" -lt 20 ]; do
            tail -c +"$((offset + 1))" "$SERIAL" >"$prefix.serial.log"
            if _ssh 'cat /dev/vcs1' >"$prefix.tty1.log" &&
                grep -Fq "login:" "$prefix.serial.log" && grep -Fq "login:" "$prefix.tty1.log"; then
                started=1
            fi
            if [ "$started" = 1 ] && wizard_console_details_present "$prefix.serial.log" "$token" "$host" &&
                wizard_console_details_present "$prefix.tty1.log" "$token" "$host"; then
                found=1
                break
            fi
            [ "$mode" != control ] || [ "$started" = 0 ] || break
            sleep 1
            n=$((n + 1))
        done
    fi
    wizard_console_record_capture "${prefix##*/}-tty1" "$prefix.tty1.log" || return 1
    wizard_console_record_capture "${prefix##*/}-serial" "$prefix.serial.log" || return 1
    wizard_console_record_capture "${prefix##*/}-getty" "$prefix.getty.txt" || return 1
    [ "$ready" = 1 ] && [ "$started" = 1 ] || return 1
    if [ "$mode" = control ]; then
        [ "$found" = 0 ]
    else
        [ "$found" = 1 ]
    fi
)

_setup_again_console_proof() {
    local host boot_id prefix n=0 monitor_ok=0
    # shellcheck disable=SC2034
    local SSH_TIMEOUT=30
    host=$(_ssh hostname 2>/dev/null | tr -d '\r\n') || return 1
    boot_id=$(_ssh cat /proc/sys/kernel/random/boot_id 2>/dev/null | tr -d '\r\n') || return 1
    [[ "$boot_id" =~ ^[0-9a-f-]{36}$ ]] || return 1
    prefix="${TMPDIR:-$(dirname "$SERIAL")}/setup-console-$boot_id"
    while [ "$n" -lt 20 ]; do
        if _ssh 'cat /dev/vcs1' >"$prefix.tty1.log" && wizard_console_details_present "$prefix.tty1.log" "$token" "$host"; then
            monitor_ok=1
            break
        fi
        sleep 1
        n=$((n + 1))
    done
    wizard_console_record_capture "$boot_id-initial-tty1" "$prefix.tty1.log" || return 1
    [ "$monitor_ok" = 1 ] && ok "the current setup URL and token are readable on tty1" || {
        bad "the current setup URL and token are missing from the tty1 capture"
        return 1
    }
    _setup_again_console_race control "$prefix-control" "$host" &&
        ok "getty startup loses the paused announcement without issue publication (negative control)" || {
        bad "the getty-start negative control did not execute or accepted missing issue publication"
        return 1
    }
    _setup_again_console_race published "$prefix-published" "$host" &&
        ok "both gettys print the current URL and token while the direct announcement is paused" || {
        bad "the current URL and token did not survive getty startup on both consoles"
        return 1
    }
}
