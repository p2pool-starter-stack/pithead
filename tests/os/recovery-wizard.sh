# shellcheck shell=bash disable=SC2034,SC2154
: "${OS_RUN_SUITE:?source via the suite runner}"

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
