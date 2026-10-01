# shellcheck shell=bash
# Original read has no new timeout. Only the additional failure-time read is timed.
compose_read() { # <private directory> <prefix> <snippet> [collector options]
    local dir="$1" prefix="$2" snippet="$3" declarations command marker
    shift 3
    marker="__compose_exit_$(python3 -c 'import secrets; print(secrets.token_hex(16))')="
    command="$snippet; rc=\$?; printf '\n$marker%s\n' \"\$rc\" >&2; exit \"\$rc\""
    if [ "$prefix" = compose-ps-all ]; then
        command="timeout --kill-after=1 5 bash -c $(quote_arg "$command")"
    fi
    declarations="$(declare -p IT_MODE IT_REMOTE_DIR IT_SSH_DEST IT_SSH_OPTS 2>/dev/null)"
    python3 "${BASH_SOURCE[0]%/*}/compose-read.py" "$@" --status-marker "$marker" "$dir" "$prefix" \
        bash -c "$(declare -f rx quote_arg)
$declarations
rx $(quote_arg "$command")"
}

retain_compose_read() { # <private directory> <prefix> <artifact directory>
    local stream
    for stream in stdout stderr; do
        redact <"$1/$2.$stream" >"$3/$2.$stream" || return 1
    done
    cp "$1/$2.json" "$3/$2.json"
}

capture_missing_service() { # <private snapshot directory> <scenario> <service>
    local private="$1" name="$2" svc="$3" dir="$OUT_DIR/$2"
    [ ! -e "$private/captured" ] || return 0
    # Set before any I/O: even a failed capture is attempted only once per snapshot.
    touch "$private/captured" || return 1
    compose_read "$private" compose-ps-all 'docker compose ps -a' --seconds 8 || true
    mkdir -p "$dir" || return 1
    {
        printf 'scenario=%s\nfailed_service=%s\ncaptured_at=%s\n' "$name" "$svc" "$(date -u +%FT%TZ)"
        retain_compose_read "$private" running-services "$dir" &&
            retain_compose_read "$private" compose-ps-all "$dir" || echo 'capture_error=artifact retention failed'
    } | redact >"$dir/service-read.txt"
}
