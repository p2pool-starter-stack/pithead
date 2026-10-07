# shellcheck shell=bash
boot_label_serial_verdict() { # <serial-log> <byte-offset> <version> <current-slot> <previous-slot> [media-label] [previous-version]
    local log="$1" offset="$2" version="$3" current="$4" previous="$5" media="${6:-}" old="${7:-$3}" serial
    [[ "$offset" =~ ^[0-9]+$ ]] || return 1
    serial=$(tail -c "+$((offset + 1))" "$log" 2>/dev/null)
    grep -Fq "${media}Pithead $version (slot $current, current)" <<<"$serial" &&
        grep -Fq "${media}Pithead $old (slot $previous, previous)" <<<"$serial" || {
        printf 'serial menu did not name Pithead %s as slot %s current and slot %s previous' \
            "$version" "$current" "$previous"
        return 1
    }
    if [ -n "$media" ]; then
        grep -Fq "${media}Set up again (setup wizard; keeps saved settings)" <<<"$serial" || {
            printf 'serial menu did not show the complete media-prefixed setup title'
            return 1
        }
    fi
    printf 'serial menu names Pithead %s as slot %s current and slot %s previous' \
        "$version" "$current" "$previous"
}
