# shellcheck shell=bash
POH_BEFORE_WORKERS=""
POH_BEFORE_FAILURES=""

_poh_payload() { # <mode>
    cat "$SCRIPT_DIR/post-reboot-health-guest.sh" \
        "$SCRIPT_DIR/../integration/lib/reset-restore-web.sh" \
        "$SCRIPT_DIR/../integration/lib/post-op-invariants.sh"
    printf '\npoh_main %s\n' "$1"
}

post_reboot_health_begin() {
    local out
    out=$(SSH_TIMEOUT=120 _ssh "printf %s '$(_poh_payload snapshot | base64 | tr -d '\n')' | base64 -d | bash") || {
        bad "post-reboot health: pre-step snapshot failed"
        return 1
    }
    POH_BEFORE_WORKERS=$(sed -n 's/^POH_WORKERS=//p' <<<"$out" | tr -d '\r')
    POH_BEFORE_FAILURES=$(sed -n 's/^POH_FAILURES=//p' <<<"$out" | tr -d '\r')
}

post_reboot_health_verify() { # <label> [probes allowed]
    local label="$1" out rc=0 line seen=0
    out=$(SSH_TIMEOUT=900 _ssh "printf %s '$(_poh_payload verify | base64 | tr -d '\n')' | base64 -d |
        POH_LABEL=$(printf '%q' "$label") POH_WORKERS=$(printf '%q' "$POH_BEFORE_WORKERS") POH_FAILURES=$(printf '%q' "$POH_BEFORE_FAILURES") POI_PROBES_ALLOWED=${2:-0} bash") || rc=$?
    while IFS= read -r line; do
        case "$line" in
        'POH PASS '*)
            seen=$((seen + 1))
            ok "${line#POH PASS }"
            ;;
        'POH FAIL '*)
            seen=$((seen + 1))
            bad "${line#POH FAIL }"
            ;;
        'POH SKIP '*) info "${line#POH SKIP }" ;;
        esac
    done <<<"$out"
    if [ "$seen" -eq 0 ]; then
        bad "$label: guest health checks produced no verdict (exit $rc)"
        return 1
    fi
    return "$rc"
}
