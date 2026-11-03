# shellcheck shell=bash
approval_restore_step() {
    local operation="$1" helper rc=0
    local -a statuses
    shift
    helper="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/approval-restore-output.py"
    printf '  approval restore operation=%s begin\n' "$operation"
    (
        "$@" 2>&1 || rc=$?
        if [ -s "${SSH_ERR:-}" ]; then
            cat -- "$SSH_ERR"
        fi
        exit "$rc"
    ) | python3 "$helper" 2>/dev/null
    statuses=("${PIPESTATUS[@]}")
    printf '  approval restore operation=%s exit=%s\n' "$operation" "${statuses[0]}"
    [ "${statuses[0]}" -eq 0 ] || return "${statuses[0]}"
    if [ "${statuses[1]}" -ne 0 ]; then
        printf '  approval restore operation=%s diagnostic-filter-failed\n' "$operation" >&2
        return 1
    fi
}

approval_restore_pending() {
    [ -n "$APPROVAL_RESTORE_SNAPSHOT" ] || return 0
    approval_restore_step drain _control_requests_drained || return $?
    approval_restore_step install _ssh 'install -m 600 /data/pithead/data/control/.os1966-original-config.json /data/pithead/config.json' || return $?
    approval_restore_step apply _ssh 'cd /data/pithead && ./pithead apply -y' || return $?
    approval_restore_step compare _ssh 'cmp -s /data/pithead/config.json /data/pithead/data/control/.os1966-original-config.json' || return $?
    approval_restore_step remove _ssh 'rm -f /data/pithead/data/control/.os1966-original-config.json' || return $?
    APPROVAL_RESTORE_SNAPSHOT=""
}
