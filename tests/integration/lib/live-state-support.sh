# shellcheck shell=bash
# Private CoW snapshots for exact rollback of writable live mount sources.

capture_state_snapshots() { # <stateful mount TSV>
    local source parent base snap nonce prior covered kept=""
    nonce="$$-$(date +%s)"
    UPGRADE_STATE_SNAPSHOTS=""
    UPGRADE_STATE_OLD_DIRS=""
    while IFS= read -r source; do
        [ -n "$source" ] || continue
        [[ "$source" = /* && "$source" != / ]] || return 1
        covered=0
        while IFS= read -r prior; do
            [ -z "$prior" ] || case "$source/" in "$prior/"*) covered=1 ;; esac
        done <<<"$kept"
        [ "$covered" = 0 ] || continue
        parent="$(dirname "$source")" base="$(basename "$source")"
        snap="$parent/.pithead-live-$base-$nonce"
        rx "test -d $(quote_arg "$source") && test ! -L $(quote_arg "$source") && test ! -e $(quote_arg "$snap") && sudo -n cp -a --reflink=always -- $(quote_arg "$source") $(quote_arg "$snap")" || {
            rx "sudo -n rm -rf -- $(quote_arg "$snap")" >/dev/null 2>&1 || true
            cleanup_state_snapshots
            return 1
        }
        kept+="${kept:+$'\n'}$source"
        UPGRADE_STATE_SNAPSHOTS+="${UPGRADE_STATE_SNAPSHOTS:+$'\n'}$source"$'\t'"$snap"
    done < <(printf '%s\n' "$1" | cut -f3 | sort -u)
    [ -n "$UPGRADE_STATE_SNAPSHOTS" ]
}

restore_state_snapshots() {
    local source snap replacement old nonce journal=""
    nonce="$$-$(date +%s)"
    while IFS=$'\t' read -r source snap; do
        if [ -z "$source" ] || [ -z "$snap" ] || [[ "$source" != /* || "$source" = / || "$snap" != "$(dirname "$source")/.pithead-live-"* ]]; then
            cleanup_restore_replacements "$journal"
            return 1
        fi
        replacement="$source.pithead-restore-$nonce" old="$source.pithead-old-$nonce"
        rx "test -d $(quote_arg "$snap") && test ! -e $(quote_arg "$replacement") && test ! -e $(quote_arg "$old") && sudo -n cp -a --reflink=always -- $(quote_arg "$snap") $(quote_arg "$replacement")" || {
            cleanup_restore_replacements "$journal"
            return 1
        }
        journal+="${journal:+$'\n'}$source"$'\t'"$replacement"$'\t'"$old"
    done <<<"$UPGRADE_STATE_SNAPSHOTS"
    while IFS=$'\t' read -r source replacement old; do
        rx "sudo -n mv -- $(quote_arg "$source") $(quote_arg "$old") && { sudo -n mv -- $(quote_arg "$replacement") $(quote_arg "$source") || { sudo -n mv -- $(quote_arg "$old") $(quote_arg "$source"); false; }; }" || {
            rollback_restored_state
            cleanup_restore_replacements "$journal"
            return 1
        }
        UPGRADE_STATE_OLD_DIRS="$source"$'\t'"$old${UPGRADE_STATE_OLD_DIRS:+$'\n'$UPGRADE_STATE_OLD_DIRS}"
    done <<<"$journal"
}

cleanup_restore_replacements() { # <source/replacement/old TSV>
    local _source replacement _old
    while IFS=$'\t' read -r _source replacement _old; do
        [ -z "$replacement" ] || rx "sudo -n rm -rf -- $(quote_arg "$replacement")" >/dev/null 2>&1 || true
    done <<<"$1"
}

rollback_restored_state() {
    local source old failed=0 replacement nonce
    nonce="$$-$(date +%s)"
    while IFS=$'\t' read -r source old; do
        [ -z "$old" ] || {
            replacement="$source.pithead-failed-$nonce"
            rx "test -d $(quote_arg "$old") && test ! -e $(quote_arg "$replacement") && sudo -n mv -- $(quote_arg "$source") $(quote_arg "$replacement") && { sudo -n mv -- $(quote_arg "$old") $(quote_arg "$source") || { sudo -n mv -- $(quote_arg "$replacement") $(quote_arg "$source"); false; }; } && sudo -n rm -rf -- $(quote_arg "$replacement")" || failed=1
        }
    done <<<"${UPGRADE_STATE_OLD_DIRS:-}"
    [ "$failed" != 0 ] || UPGRADE_STATE_OLD_DIRS=""
    return "$failed"
}

cleanup_state_snapshots() {
    local _source snap
    while IFS=$'\t' read -r _source snap; do
        [ -z "$snap" ] || rx "sudo -n rm -rf -- $(quote_arg "$snap")" >/dev/null 2>&1 || true
    done <<<"${UPGRADE_STATE_SNAPSHOTS:-}"
    while IFS=$'\t' read -r _source snap; do
        [ -z "$snap" ] || rx "sudo -n rm -rf -- $(quote_arg "$snap")" >/dev/null 2>&1 || true
    done <<<"${UPGRADE_STATE_OLD_DIRS:-}"
}

derived_state_fingerprint() {
    rx 'set -euo pipefail; source ./pithead; d=$(control_unit_dir); { for p in .env Caddyfile; do [ -f "$p" ] && sha256sum "$p" || exit 1; done; [ -d build ] || exit 1; find build -type f -exec sha256sum {} +; for p in "$d/pithead-control.path" "$d/pithead-control.service" /run/systemd/system/ssh.service.d/pithead.conf /run/pithead-ssh/authorized_keys; do if [ -f "$p" ]; then sudo -n sha256sum "$p" || exit 1; else echo "absent $p"; fi; done; systemctl show -p UnitFileState --value pithead-control.path; systemctl show -p ActiveState --value pithead-control.path; sudo -n passwd -S root | awk "{print \\$2}"; } | sort | sha256sum | cut -d" " -f1'
}

reset_control_units_for_render() {
    rx 'source ./pithead; [ "$OS_TYPE" != Linux ] || { d=$(control_unit_dir); sudo -n rm -f "$d/pithead-control.path" "$d/pithead-control.service" && sudo -n systemctl daemon-reload; }'
}
