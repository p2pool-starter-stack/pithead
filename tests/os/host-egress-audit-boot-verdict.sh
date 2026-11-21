# shellcheck shell=bash

host_egress_audit_counter() {
    printf '%s' "$2" | awk -v n="$1" '$0 ~ "comment \"" n "\"" && /counter packets/ { for (i = 1; i <= NF; i++) if ($i == "packets") { print $(i + 1); exit } }'
}

host_egress_audit_would_drop() {
    host_egress_audit_counter would_drop "$1"
}

host_egress_audit_delta() {
    case "${1:-}" in '' | *[!0-9]*) return 0 ;; esac
    case "${2:-}" in '' | *[!0-9]*) return 0 ;; esac
    printf '%s\n' "$((10#$1 - 10#$2))"
}

host_egress_audit_boot_verdict() {
    local active="$1" table="$2" before="$3" after="$4" dial="$5"
    local noise="${6:-}" probe="${7:-}" lb_rise="${8:-}"
    if [ "$active" != "active" ]; then
        echo "log-only host egress audit unit did not run this boot (is-active: ${active:-unreadable})"
        return 1
    fi
    case "$table" in
    *"hook output priority"*) ;;
    *)
        echo "no host inet output table after boot: ${table:0:160}"
        return 1
        ;;
    esac
    case "$table" in
    *'comment "would_drop"'* | *"'would_drop'"*) ;;
    *)
        echo "the host inet output table has no logged would_drop rule: ${table:0:160}"
        return 1
        ;;
    esac
    if printf '%s\n' "$table" | grep -Eq '(^|[[:space:]])(accept|drop|reject)([[:space:]]|$)'; then
        echo "the log-only host inet output table carries a terminal verdict — it is enforcing or shadowed, not auditing"
        return 1
    fi
    if printf '%s\n' "$table" | grep 'limit rate' | grep -vq 'oifname != "lo"'; then
        echo "the audit table logs from an ungated rule — every output packet, loopback included, would be logged as a would-be drop"
        return 1
    fi
    local n
    for n in "$before" "$after"; do
        case "$n" in
        '' | *[!0-9]*)
            echo "would_drop counter unreadable across the test flow (before ${before:-unreadable}, after ${after:-unreadable})"
            return 1
            ;;
        esac
    done
    if [ "$after" -le "$before" ]; then
        echo "would_drop did not rise across the expected outbound flow (before $before, after $after) — the flow was counted elsewhere or the table is not on the output path"
        return 1
    fi
    for n in "$noise" "$probe" "$lb_rise"; do
        case "$n" in
        '' | *[!0-9]*)
            echo "loopback-exclusion counters unreadable (idle window ${noise:-unreadable}, probe window ${probe:-unreadable}, loopback rise ${lb_rise:-unreadable}) — the loopback leg proved nothing"
            return 1
            ;;
        esac
    done
    if [ "$lb_rise" -lt 100 ]; then
        echo "the loopback probe never reached lo (loopback counter rose only $lb_rise of the 100+ packets sent) — the exclusion leg proved nothing"
        return 1
    fi
    if [ $((probe - noise)) -gt 50 ]; then
        echo "loopback traffic leaks into the would_drop counter (idle window $noise packets, loopback probe window $probe) — each class rule must keep its class out of the gated would_drop rule"
        return 1
    fi
    if [ "$dial" != "0" ]; then
        echo "the expected outbound flow failed through the log-only table (exit $dial) — the audit view must change no routing"
        return 1
    fi
    echo "log-only host inet output table loaded at boot, counted the expected flow (would_drop $before -> $after), kept its loopback probe out of would_drop (idle $noise, probe window $probe) and dropped nothing"
    return 0
}
