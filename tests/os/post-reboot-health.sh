# shellcheck shell=bash
POH_BEFORE_WORKERS=""
POH_BEFORE_FAILURES=""
POH_BEFORE_CONTAINERS=""
POH_CONTAINER_RE="."

_poh_payload() {
    cat "$SCRIPT_DIR/post-reboot-health-guest.sh" \
        "$SCRIPT_DIR/../integration/lib/reset-restore-web.sh" \
        "$SCRIPT_DIR/../integration/lib/post-op-invariants.sh"
    printf '\npoh_main %s\n' "$1"
}

post_reboot_health_begin() {
    local out
    out=$(SSH_TIMEOUT=120 _ssh "printf %s '$(_poh_payload snapshot | base64 | tr -d '\n')' | base64 -d | POH_CONTAINER_RE=$(printf '%q' "$POH_CONTAINER_RE") bash") || {
        bad "post-reboot health: pre-step snapshot failed"
        return 1
    }
    POH_BEFORE_WORKERS=$(sed -n 's/^POH_WORKERS=//p' <<<"$out" | tr -d '\r')
    POH_BEFORE_FAILURES=$(sed -n 's/^POH_FAILURES=//p' <<<"$out" | tr -d '\r')
    POH_BEFORE_CONTAINERS=$(sed -n 's/^POH_CONTAINERS=//p' <<<"$out" | tr -d '\r')
}

post_reboot_health_verify() {
    local label="$1" out rc=0 line done=0
    out=$(SSH_TIMEOUT=900 _ssh "printf %s '$(_poh_payload verify | base64 | tr -d '\n')' | base64 -d |
        POH_LABEL=$(printf '%q' "$label") POH_WORKERS=$(printf '%q' "$POH_BEFORE_WORKERS") POH_FAILURES=$(printf '%q' "$POH_BEFORE_FAILURES") POH_CONTAINERS=$(printf '%q' "$POH_BEFORE_CONTAINERS") POH_CONTAINER_RE=$(printf '%q' "$POH_CONTAINER_RE") POI_PROBES_ALLOWED=${2:-0} bash") || rc=$?
    while IFS= read -r line; do
        line=${line%$'\r'}
        case "$line" in
        'POH PASS '*) ok "${line#POH PASS }" ;;
        'POH FAIL '*) bad "${line#POH FAIL }" ;;
        'POH SKIP '*) info "${line#POH SKIP }" ;;
        'POH DONE') done=1 ;;
        esac
    done <<<"$out"
    if [ "$done" -eq 0 ]; then
        bad "$label: guest health checks did not finish (exit $rc)"
        return 1
    fi
    return "$rc"
}
