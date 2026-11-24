# shellcheck shell=bash
# Real ownership checks shared by reset/restore, auth recovery and setup after uninstall.
rr_setup_page_ready() {
    local target
    rx "docker inspect --format '{{.State.Running}}' pithead-wizard" 2>/dev/null | grep -qx true || return 1
    target="${IT_SSH_DEST##*@}"
    [ -n "$target" ] || return 1
    # Probe from the harness host: the guest's loopback is not the operator's setup page.
    curl --noproxy '*' -fsSk --max-time 5 "https://$target/" 2>/dev/null | grep -qi 'Pithead setup'
}

rr_wizard_absent() {
    local names
    names=$(rx 'docker ps -a --format "{{.Names}}"') || return 1
    ! grep -qx pithead-wizard <<<"$names"
}

rr_caddy_snapshot() {
    local state
    state=$(rx "docker inspect --format '{{.Id}} {{.RestartCount}} {{.State.StartedAt}} {{.State.Running}} {{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}' caddy") || return 1
    [[ "$state" == *' true healthy' ]] || return 1
    printf '%s' "$state"
}

rr_caddy_stable() {
    local before current deadline
    wait_for 60 5 "Caddy healthy" rr_caddy_snapshot >/dev/null || return 1
    before=$(rr_caddy_snapshot) || return 1
    deadline=$(($(now_s) + 60))
    while :; do
        sleep 5
        current=$(rr_caddy_snapshot) || return 1
        [ "$current" = "$before" ] || return 1
        [ "$(now_s)" -lt "$deadline" ] || return 0
    done
}

rr_dashboard_response() {
    local host port scheme expected response code secure auth detected_channel
    host=$(env_on_box HOST_IP) || return 1
    [ -n "$host" ] || return 1
    port=$(env_on_box HOST_PORT) || return 1
    secure=$(env_on_box DASHBOARD_SECURE) || return 1
    auth=$(env_on_box DASHBOARD_AUTH_HASH_B64) || return 1
    if [ "$secure" = false ]; then
        scheme=http
        port=${port:-80}
    else
        scheme=https
        port=${port:-443}
    fi
    expected=200
    [ -z "$auth" ] || expected=401
    # The appliance always requires auth, even if an erroneous render omitted the hash.
    detected_channel=$(rx 'source ./pithead || exit; if is_appliance; then printf appliance; else printf diy; fi') || return 1
    case "$detected_channel" in appliance) expected=401 ;; diy) ;; *) return 1 ;; esac
    response=$(rx "curl --noproxy '*' -ksS --max-time 15 --resolve $(quote_arg "$host:$port:127.0.0.1") -w '\n%{http_code}' $(quote_arg "$scheme://$host:$port/")") || return 1
    code=${response##*$'\n'}
    [ "$code" = "$expected" ] && ! grep -qi 'Pithead setup' <<<"$response"
}

rr_web_ports_owned_by_dashboard() { # <label>; collect every row, including on the negative control
    local label="$1" failures_before="$IT_FAIL"
    if wait_for 60 5 "wizard removed" rr_wizard_absent; then
        it_pass "$label: no pithead-wizard container"
    else
        it_fail "$label: no pithead-wizard container" "wizard still present or census unavailable after 60s"
    fi
    if rr_caddy_stable; then
        it_pass "$label: Caddy running/healthy without churn for 60s"
    else
        it_fail "$label: Caddy running/healthy without churn for 60s" "Id, RestartCount, StartedAt or health changed"
    fi
    if rr_dashboard_response; then
        it_pass "$label: dashboard owns the web response"
    else
        it_fail "$label: dashboard owns the web response" "wrong HTTP code, setup page, or failed request"
    fi
    if [ "$IT_FAIL" -gt "$failures_before" ]; then
        rx 'ss -ltnp; docker logs --tail 40 caddy' 2>&1 | redact
        return 1
    fi
}
