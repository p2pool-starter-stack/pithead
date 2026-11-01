# shellcheck shell=bash disable=SC2034 # POI_* state is read across calls
POI_WORKERS=""
POI_FAILURES=""

poi_workers_missing() {
    comm -23 <(printf '%s\n' "$1" | sed '/^$/d' | sort -u) <(printf '%s\n' "$2" | sed '/^$/d' | sort -u)
}

poi_failures_unchanged() {
    case "$1$2" in '' | *[!0-9]*) return 1 ;; esac
    [ "$1" = "$2" ]
}

poi_containers_drift() {
    local line name
    while IFS= read -r line; do
        [ -n "$line" ] || continue
        name=${line%% *}
        grep -qxF -- "$line" <<<"$1" || printf 'changed: %s\n' "$name"
        case "$line" in *' true healthy' | *' true none') ;; *) printf 'unhealthy: %s\n' "$name" ;; esac
    done <<<"$2"
    while IFS= read -r line; do
        [ -n "$line" ] || continue
        name=${line%% *}
        grep -q "^$name " <<<"$2" || printf 'missing: %s\n' "$name"
    done <<<"$1"
}

poi_failed_units() {
    grep -Ei '^[^ ]*(pithead|xmrig)[^ ]*\.(service|socket|timer|mount|target)' <<<"$1"
}

poi_online_workers() { api_state | jq -r '.workers[]? | select(.status == "online") | .name' 2>/dev/null | sort -u; }

poi_failures_24h() { rx "curl -fsS --max-time 10 http://127.0.0.1:8000/api/access" 2>/dev/null | jq -r '.failures_24h // empty' 2>/dev/null; }

poi_container_snapshot() {
    rx "docker ps -q --filter label=com.docker.compose.project=pithead | xargs -r docker inspect --format '{{.Name}} {{.Id}} {{.RestartCount}} {{.State.StartedAt}} {{.State.Running}} {{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}'" 2>/dev/null | sed 's#^/##' | sort
}

poi_workers_reconnected() { [ -z "$(poi_workers_missing "$POI_WORKERS" "$(poi_online_workers)")" ]; }

post_op_begin() {
    POI_WORKERS=$(poi_online_workers)
    POI_FAILURES=$(poi_failures_24h)
}

post_op_invariants() {
    local label="$1" bound="${POI_RECONNECT_S:-300}" missing after_failures before after drift units channel
    if [ -z "$POI_WORKERS" ]; then
        it_skip_leg "$label: workers reconnect" "no worker was online before the step" "by-design"
    else
        if wait_for "$bound" 10 "$label: workers reconnect" poi_workers_reconnected; then
            it_pass "$label: every worker online before the step is online again"
        else
            missing=$(poi_workers_missing "$POI_WORKERS" "$(poi_online_workers)" | tr '\n' ' ')
            it_fail "$label: every worker online before the step is online again" "still offline after ${bound}s: ${missing:-unreadable}"
        fi
    fi
    after_failures=$(poi_failures_24h)
    if poi_failures_unchanged "$POI_FAILURES" "$after_failures"; then
        it_pass "$label: failures_24h unchanged by the step"
    else
        it_fail "$label: failures_24h unchanged by the step" "before [${POI_FAILURES}], after [${after_failures}]"
    fi
    if wait_for 60 5 "$label: wizard removed" rr_wizard_absent; then
        it_pass "$label: no pithead-wizard container"
    else
        it_fail "$label: no pithead-wizard container" "wizard still present or census unavailable after 60s"
    fi
    if rr_dashboard_response; then
        it_pass "$label: dashboard, not the setup page, owns the web response"
    else
        it_fail "$label: dashboard, not the setup page, owns the web response" "wrong HTTP code, setup page, or failed request"
    fi
    before=$(poi_container_snapshot)
    sleep "${POI_STABLE_S:-60}"
    after=$(poi_container_snapshot)
    drift=$(poi_containers_drift "$before" "$after")
    if [ -n "$before" ] && [ -z "$drift" ]; then
        it_pass "$label: every running container healthy with a steady Id, StartedAt and restart count"
    else
        it_fail "$label: every running container healthy with a steady Id, StartedAt and restart count" "${drift:-no running containers}"
    fi
    if channel=$(rx 'source ./pithead || exit; if is_appliance; then printf appliance; else printf diy; fi'); then
        if [ "$channel" = appliance ]; then
            if units=$(rx 'systemctl --failed --plain --no-legend'); then
                units=$(poi_failed_units "$units")
                if [ -z "$units" ]; then
                    it_pass "$label: no failed pithead or xmrig unit"
                else
                    it_fail "$label: no failed pithead or xmrig unit" "$units"
                fi
            else
                it_fail "$label: no failed pithead or xmrig unit" "systemctl --failed unreadable"
            fi
        fi
    else
        it_fail "$label: no failed pithead or xmrig unit" "channel probe unreadable"
    fi
    post_op_begin
}
