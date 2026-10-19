# shellcheck shell=bash
: "${INTEGRATION_RUN_SUITE:?source via the suite runner}"
# Observe more than two old 30-second churn periods, but less than one real dwell.
# Read the shipped constant, not the source checkout; a restart invalidates the window.
assert_xvb_off_no_dwell_churn() {
    local row="XvB off: no P2Pool dwell churn (#3252)"
    local enabled
    if ! enabled="$(env_on_box XVB_ENABLED)"; then
        it_fail "$row" "XVB_ENABLED probe failed"
        return 0
    fi
    if [ "$enabled" = "true" ]; then
        it_skip_leg "$row" "XvB is enabled" "by-design"
        return 0
    fi
    local dwell identity final_identity started now since until logs state rejected early switches i
    dwell="$(rx "timeout 15 docker exec dashboard python3 -c 'from mining_dashboard.config.config import XVB_TIME_ALGO_MS; print(XVB_TIME_ALGO_MS)'" 2>/dev/null)" || dwell=""
    # 95 seconds catches at least three old ticks. It must fit within the real dwell,
    # allowing at most one legitimate cycle boundary anywhere in the observation.
    if ! [[ "$dwell" =~ ^[0-9]{1,9}$ ]] || [ "$dwell" -le 95000 ]; then
        it_fail "$row" "unreadable or too-short XVB_TIME_ALGO_MS"
        return 0
    fi
    identity="$(rx "timeout 15 docker inspect --format '{{.Id}} {{.State.StartedAt}}' dashboard" 2>/dev/null)" || identity=""
    started="$(rx "date -d $(quote_arg "${identity#* }") +%s" 2>/dev/null)" || started=""
    now="$(rx 'date +%s' 2>/dev/null)" || now=""
    if [ -z "$identity" ] || ! [[ "$started $now" =~ ^[0-9]{1,12}\ [0-9]{1,12}$ ]] || [ "$now" -lt "$started" ]; then
        it_fail "$row" "could not establish dashboard uptime"
        return 0
    fi
    if [ "$((now - started))" -lt 60 ]; then
        sleep "$((60 - now + started))"
    fi
    logs="$(rx "timeout 15 docker logs --since $started dashboard 2>&1")" || {
        it_fail "$row" "dashboard startup log unreadable"
        return 0
    }
    if [[ "$logs" != *"Service Started: Algorithm Control Loop"* ]]; then
        it_skip_leg "$row" "algorithm loop never started" "by-design"
        return 0
    fi
    since="$(rx 'date +%s' 2>/dev/null)" || since=""
    if ! [[ "$since" =~ ^[0-9]{1,12}$ ]]; then
        it_fail "$row" "observation clock unreadable"
        return 0
    fi
    rejected=false
    for ((i = 0; i <= 19; i++)); do
        state="$(api_state)" || state=""
        if ! rejected="$(printf '%s' "$state" | jq -er 'if (.badges | type) == "array" then any(.badges[]; .text | startswith("Workers rejected")) | tostring else error("missing badges") end' 2>/dev/null)"; then
            it_fail "$row" "worker rejection state unreadable"
            return 0
        fi
        if [ "$rejected" = true ]; then
            it_skip_leg "$row" "algorithm paused because workers are rejected" "by-design"
            return 0
        fi
        [ "$i" = 19 ] || sleep 5
    done
    until="$(rx 'date +%s' 2>/dev/null)" || until=""
    if ! [[ "$until" =~ ^[0-9]{1,12}$ ]] || [ "$((until - since))" -lt 95 ] || [ "$(((until - since) * 1000))" -ge "$dwell" ]; then
        it_fail "$row" "observation must span 95 seconds and remain shorter than the dwell"
        return 0
    fi
    if ! final_identity="$(rx "timeout 15 docker inspect --format '{{.Id}} {{.State.StartedAt}}' dashboard" 2>/dev/null)"; then
        it_fail "$row" "dashboard identity recheck failed"
        return 0
    fi
    if [ "$final_identity" != "$identity" ]; then
        it_fail "$row" "dashboard restarted during observation"
        return 0
    fi
    logs="$(rx "timeout 15 docker logs --since $since --until $until dashboard 2>&1")" || {
        it_fail "$row" "observation log unreadable"
        return 0
    }
    if ! mkdir -p "$OUT_DIR/${IT_CURRENT_SCENARIO:-check}.xvb-off-dwell" ||
        ! printf '%s\n' "$logs" | redact >"$OUT_DIR/${IT_CURRENT_SCENARIO:-check}.xvb-off-dwell/dashboard.log"; then
        it_fail "$row" "could not retain observation log"
        return 0
    fi
    early="$(printf '%s\n' "$logs" | awk '/ending P2Pool dwell early/ {n++} END {print n+0}')"
    switches="$(printf '%s\n' "$logs" | awk '/Switched Proxy to mode: P2POOL/ {n++} END {print n+0}')"
    it_log "   XvB off: XVB_TIME_ALGO_MS=$dwell; window=$((until - since))s; early=$early; switches=$switches"
    if [ "$early" = 0 ] && [ "$switches" -le 1 ]; then
        it_pass "$row"
    else
        it_fail "$row" "early=$early; P2POOL switches=$switches"
    fi
}
