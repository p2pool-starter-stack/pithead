# shellcheck shell=bash

host_egress_audit_would_drop() {
    printf '%s' "$1" | awk '/comment "would_drop"/ && /counter packets/ { for (i = 1; i <= NF; i++) if ($i == "packets") { print $(i + 1); exit } }'
}

host_egress_audit_boot_verdict() {
    local active="$1" table="$2" before="$3" after="$4" dial="$5"
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
    if [ "$dial" != "0" ]; then
        echo "the expected outbound flow failed through the log-only table (exit $dial) — the audit view must change no routing"
        return 1
    fi
    echo "log-only host inet output table loaded at boot, counted the expected flow (would_drop $before -> $after) and dropped nothing"
    return 0
}
