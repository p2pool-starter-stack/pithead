# shellcheck shell=bash
# Failure-time snapshot, before later reboots replace the failing container and config (#3001).
caddy_failure_evidence() {
    # shellcheck disable=SC2034 # _ssh reads its deadline through dynamic scope
    local SSH_TIMEOUT="${SSH_PROBE_TIMEOUT:-20}" snapshot rc=0
    snapshot=$(_ssh 'python3 -' <"$SCRIPT_DIR/caddy-failure-evidence.py" 2>/dev/null) || rc=$?
    if [ "$rc" -ne 0 ] || ! printf '%s' "$snapshot" | jq -e 'type == "object"' >/dev/null 2>&1; then
        printf '  Caddy failure snapshot: unavailable (ssh exit %s)\n' "$rc" >&2
        return 0
    fi
    printf '  Caddy failure snapshot: %s\n' "$snapshot" >&2
}
