# shellcheck shell=bash

host_egress_watchdog_state() {
    printf '%s' "$1" | sed -n 's/.*watchdog=\([a-z-]*\).*/\1/p' | head -n1
}

host_egress_watchdog_rise() {
    printf '%s' "$1" | sed -n 's/.*watchdog=[a-z-]* (rise \([0-9]*\) since the last check).*/\1/p' | head -n1
}

host_egress_watchdog_boot_verdict() {
    local allow_v leak_v leak_r
    allow_v=$(host_egress_watchdog_state "$1")
    leak_v=$(host_egress_watchdog_state "$2")
    leak_r=$(host_egress_watchdog_rise "$2")
    case "$allow_v" in
    allowlisted) ;;
    clean)
        echo "the allowlisted TLS flow over tcp 443 was never counted: the watchdog stayed clean because it saw no rise at all, so its silence proved nothing"
        return 1
        ;;
    '')
        echo "the egress check on a booted appliance with the audit table loaded printed no watchdog verdict: ${1:0:160}"
        return 1
        ;;
    leaking)
        echo "the allowlisted TLS flow alerted: watchdog=leaking while only tcp 443 (an allowlisted map row) was dialed"
        return 1
        ;;
    *)
        echo "the allowlisted flow read watchdog=${allow_v} — the audit table was proven present by the boot audit leg"
        return 1
        ;;
    esac
    if [ "$leak_v" != leaking ]; then
        echo "a deliberate clearnet probe over tcp 9999 left watchdog=${leak_v:-unreadable} — the check after an outside rise must read leaking"
        return 1
    fi
    case "$leak_r" in
    '' | *[!0-9]* | 0)
        echo "the leaking verdict carried no packet rise (${leak_r:-unreadable}) — the watchdog must count what it alerts on"
        return 1
        ;;
    esac
    echo "egress watchdog stayed quiet on the allowlisted flow (${allow_v}) and read leaking on a deliberate clearnet probe (rise $leak_r packets)"
    return 0
}
