# shellcheck shell=bash disable=SC2034,SC2154
: "${OS_RUN_SUITE:?source via the suite runner}"

_recovery_wizard_restore() {
    local token jar="${1:-}" code
    if [ -z "$jar" ]; then _setup_again_session || return 1; fi
    code=$(curl -sSk --max-time 120 -b "$jar" -F "archive=@$RECOVERY_ARCHIVE" \
        -F 'passphrase=recovery matrix fixture' "https://$ip/submit-restore" -o /dev/null -w '%{http_code}')
    if [ "$code" != 200 ]; then
        rm -f "$jar"
        return 1
    fi
    _recovery_handoff "$jar"
}

_recovery_handoff() {
    local jar="$1" until=$((SECONDS + 900)) handoff
    while [ "$SECONDS" -lt "$until" ]; do
        handoff=$(curl -sSk --max-time 5 -b "$jar" "https://$ip/api/handoff") || handoff=""
        if jq -e '(.password | type == "string" and length > 0) and (.username | type == "string" and length > 0)' <<<"$handoff" >/dev/null 2>&1; then
            DASH_USER=$(jq -r .username <<<"$handoff")
            DASH_PASS=$(jq -r .password <<<"$handoff")
            curl -fsSk --max-time 5 -b "$jar" -X POST "https://$ip/handoff-ack" >/dev/null || {
                rm -f "$jar"
                return 1
            }
            rm -f "$jar"
            return 0
        fi
        sleep 5
    done
    rm -f "$jar"
    return 1
}

_recovery_dashboard_ready() {
    local until=$((SECONDS + 180)) stable_since=0 previous="" current code body
    while [ "$SECONDS" -lt "$until" ]; do
        if _ssh "test \"\$(podman inspect caddy --format '{{.State.Running}} {{.State.Health.Status}}')\" = 'true healthy' && ! podman container exists pithead-wizard"; then
            body=$(curl --noproxy '*' -ksS --max-time 5 -w '\n%{http_code}' "https://$ip/") || body=""
            code=${body##*$'\n'}
            current=$(_ssh "podman inspect caddy --format '{{.Id}} {{.RestartCount}} {{.State.StartedAt}}'") || current=""
            if [ "$code" = 401 ] && [ -n "$current" ] && ! grep -qi 'Pithead setup' <<<"$body"; then
                if [ "$current" != "$previous" ]; then stable_since=$SECONDS; fi
                previous=$current
                [ "$((SECONDS - stable_since))" -lt 60 ] || return 0
            else
                previous=""
            fi
        else
            previous=""
        fi
        sleep 5
    done
    return 1
}
