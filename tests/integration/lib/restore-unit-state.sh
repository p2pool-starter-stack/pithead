# shellcheck shell=bash
RESTORE_UNIT_MAP=(
    EGRESS_UNIT_BEFORE:pithead-egress.service
    EGRESS_CHECK_BEFORE:pithead-egress.timer
    LAN_UNIT_BEFORE:pithead-lan-guard.service
    HOLD_UNIT_BEFORE:pithead-lan-hold.service
    LAN_CHECK_BEFORE:pithead-lan.timer
)
RESTORE_UNIT_CAPTURE=""

egress_boot_unit_state() {
    local u="${1:-pithead-egress.service}" out state="" reason rc=0
    case "$u" in
    pithead-egress.service | pithead-egress.timer | pithead-egress-check.service | pithead-lan-guard.service | pithead-lan-hold.service | pithead-lan.timer | pithead-lan-check.service) ;;
    *)
        printf '%s\n' 'unit read: unknown reason=invalid-unit' >&2
        return 0
        ;;
    esac
    out="$(on_bench "if timeout -k 1 3 systemctl cat $u >/dev/null 2>&1; then echo present; else
        set -o pipefail
        load=\$(timeout -k 1 3 systemctl show -p LoadState --value $u 2>/dev/null | head -c 64); sr=\$?
        if [ \"\$sr\" != 0 ]; then echo show-failed; else
            case \"\$load\" in
                not-found) echo absent ;;
                loaded|masked|error|bad-setting|stub|merged) echo cat-failed-\$load ;;
                '') echo load-state-empty ;;
                *) echo load-state-other ;;
            esac
        fi
    fi" 2>/dev/null)" || rc=$?
    if [ "$rc" != 0 ]; then
        reason=transport-failed
    else
        case "$out" in
        present | absent)
            state="$out"
            reason=verified
            ;;
        show-failed | cat-failed-loaded | cat-failed-masked | cat-failed-error | cat-failed-bad-setting | cat-failed-stub | cat-failed-merged | load-state-empty | load-state-other) reason="$out" ;;
        *) reason=probe-output-unavailable ;;
        esac
    fi
    printf 'unit read: unit=%s state=%s reason=%s transport_exit=%s\n' "$u" "${state:-unknown}" "$reason" "$rc" >&2
    printf '%s' "$state"
}

capture_restore_unit_states() {
    local entry var unit state rc=0
    RESTORE_UNIT_CAPTURE=""
    for entry in "${RESTORE_UNIT_MAP[@]}"; do
        var="${entry%%:*}" unit="${entry#*:}"
        state="$(egress_boot_unit_state "$unit")"
        printf -v "$var" '%s' "$state"
        printf 'unit capture: unit=%s state=%s\n' "$unit" "${state:-unknown}"
        RESTORE_UNIT_CAPTURE+=" $var=${state:-unknown}"
        [ -n "$state" ] || rc=1
    done
    return "$rc"
}

verify_restore_unit_capture() {
    local entry var unit state reason display rc=0
    for entry in "${RESTORE_UNIT_MAP[@]}"; do
        var="${entry%%:*}" unit="${entry#*:}" reason=capture-unavailable
        state="${!var:-}"
        case "${RESTORE_UNIT_CAPTURE:-} " in
        *" $var=present "* | *" $var=absent "*)
            reason="state-changed-after-capture"
            case "${RESTORE_UNIT_CAPTURE} " in
            *" $var=$state "*) reason=verified ;;
            esac
            ;;
        esac
        display=unknown
        case "$state" in present | absent) display="$state" ;; esac
        printf 'unit restore record: unit=%s state=%s reason=%s\n' "$unit" "$display" "$reason"
        [ "$reason" = verified ] || rc=1
    done
    return "$rc"
}
