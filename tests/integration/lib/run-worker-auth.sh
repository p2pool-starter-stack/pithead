# shellcheck shell=bash
: "${INTEGRATION_RUN_SUITE:?source via the suite runner}"

_worker_auth_state() {
    local state
    rx "docker logs itest-worker-auth 2>&1" | grep -Fxq "worker-api response $3" || return 1
    state=$(api_state) || return 1
    printf '%s' "$state" | jq -e --arg rig "$1" --argjson expected "$2" '
        any(.workers[]?; .name == $rig and .api_ok == $expected and .adopted == false
            and (if $expected then .rigforge.version != null else true end))' >/dev/null
}

_worker_auth_shares() {
    local state
    state=$(api_state) || return 1
    printf '%s' "$state" | jq -er '
        select(.proxy_workers > 0) | .proxy_summary.accepted
        | tostring | gsub(","; "") | tonumber | select(. >= 0)'
}

_worker_auth_shares_ready() {
    _WORKER_AUTH_SHARES=$(_worker_auth_shares)
}

_worker_auth_progress() {
    local now
    now=$(_worker_auth_shares) || return 1
    [ "$now" -gt "$1" ]
}

_worker_auth_remove() {
    [ "${_WORKER_AUTH_CONTAINER:-0}" = 1 ] || return 0
    rx 'docker rm -f itest-worker-auth >/dev/null' || return 1
    _WORKER_AUTH_CONTAINER=0
}

_worker_auth_restore() {
    [ -n "${_WORKER_AUTH_SAVED_CONFIG:-}" ] || return 0
    push_config "$_WORKER_AUTH_SAVED_CONFIG" &&
        pithead apply -y >"$OUT_DIR/worker-auth-restore.apply.log" 2>&1 &&
        wait_status_ok 240 || return 1
    _WORKER_AUTH_SAVED_CONFIG=
}

_worker_auth_abort() {
    local original_rc=$? restore_failed=0
    _worker_auth_remove || _worker_auth_remove || restore_failed=1
    _worker_auth_restore || restore_failed=1
    [ -z "$_WORKER_AUTH_FOREIGN_TRAP" ] || eval "$_WORKER_AUTH_FOREIGN_TRAP"
    [ "$restore_failed" = 0 ] || exit 1
    return "$original_rc"
}

_worker_auth_arm() {
    local fake_mode="$1" client_mode="$2" credential="$3" expected="$4" label="$5"
    local image="$6" rig="$7" saved_config="$8" host config shares code=200
    case "$label" in
    missing) code=401 ;;
    wrong) code=403 ;;
    esac
    if ! wait_for 300 3 "worker auth $label mining readiness" _worker_auth_shares_ready; then
        it_fail "worker auth $label has a live accepted-share counter" "proxy sample unavailable for 300s"
        return 1
    fi
    shares=$_WORKER_AUTH_SHARES
    _WORKER_AUTH_CONTAINER=1
    if ! rx "docker run -d --name itest-worker-auth --network mining_net --entrypoint python3 -v $(quote_arg "$IT_REMOTE_DIR/tests/integration/fakes"):/fakes:ro $(quote_arg "$image") /fakes/fake_worker_api.py --auth $fake_mode --name $(quote_arg "${rig%%+*}") --token itest-worker-api >/dev/null"; then
        it_fail "worker auth $label starts its fake API" "fixture container failed"
        return 1
    fi
    host=$(rx "docker inspect itest-worker-auth --format '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}'") || return 1
    [ -n "$host" ] || return 1
    config=$(printf '%s' "$saved_config" | jq --arg name "${rig%%+*}" --arg host "$host" \
        --arg mode "$client_mode" --arg credential "$credential" '
        .workers.api_auth = $mode | .workers.api_token = $credential |
        .workers.list = ([.workers.list[]? | select(.name != $name)] +
            [{name:$name,host:$host,port:8081}])') || return 1
    if ! push_config "$config" || ! pithead apply -y >"$OUT_DIR/worker-auth-$label.apply.log" 2>&1; then
        it_fail "worker auth $label applies supported config" "apply failed"
        return 1
    fi
    if wait_for 120 3 "worker auth $label verdict" _worker_auth_state "$rig" "$expected" "$code"; then
        it_pass "worker auth $label reports api_ok=$expected and adopted=false"
    else
        it_fail "worker auth $label reports api_ok=$expected and adopted=false" "state did not converge"
    fi
    if wait_for 120 3 "worker auth $label accepted shares" _worker_auth_progress "$shares"; then
        it_pass "worker auth $label keeps accepting shares"
    else
        it_fail "worker auth $label keeps accepting shares" "accepted counter did not grow"
    fi
    _worker_auth_remove
}

run_worker_auth_modes() {
    # shellcheck disable=SC2034
    IT_CURRENT_SCENARIO="worker-api-auth"
    local rig="${1:-}" state saved_config image failed=0 current_trap
    local -a parsed_trap
    if [ "$IT_MODE" != local ] || [ "${SKIP_MINING_ASSERTS:-0}" = 1 ]; then
        it_skip_leg "worker API auth modes" "requires a local deployed stack and a mining worker" by-design
        return 0
    fi
    state=$(api_state) || return 1
    [ -n "$rig" ] || rig=$(printf '%s' "$state" | jq -r 'first(.workers[]? | select(.status == "online") | .name) // empty')
    if [ -z "$rig" ]; then
        it_fail "worker API auth modes has a mining worker" "required fixture prerequisite absent"
        return 1
    fi
    if rx 'docker container inspect itest-worker-auth >/dev/null 2>&1'; then
        it_fail "worker API auth fixture name is unused" "existing container retained"
        return 1
    fi
    saved_config=$(rx 'cat config.json') || return 1
    image=$(rx "docker inspect dashboard --format '{{.Image}}'") || return 1
    _WORKER_AUTH_SAVED_CONFIG="$saved_config"
    current_trap=$(trap -p EXIT)
    _WORKER_AUTH_FOREIGN_TRAP=
    if [ -n "$current_trap" ]; then
        eval "parsed_trap=($current_trap)"
        _WORKER_AUTH_FOREIGN_TRAP="${parsed_trap[2]}"
    fi
    trap _worker_auth_abort EXIT
    local arm fake_mode client_mode credential expected label
    for arm in 'none none unused true open' 'name name unused true name' \
        'token none unused false missing' 'token token wrong false wrong' \
        'token token itest-worker-api true recovered'; do
        read -r fake_mode client_mode credential expected label <<<"$arm"
        if ! _worker_auth_arm "$fake_mode" "$client_mode" "$credential" "$expected" "$label" "$image" "$rig" "$saved_config"; then
            failed=1
            break
        fi
    done
    _worker_auth_remove || {
        it_fail "worker auth fixture removed" "cleanup failed"
        failed=1
    }
    if _worker_auth_restore; then
        it_pass "worker API auth restores its original config"
    else
        it_fail "worker API auth restores its original config" "restore apply or readiness failed"
        failed=1
        _WORKER_AUTH_SAVED_CONFIG="$BASELINE_CONFIG"
    fi
    if [ "${_WORKER_AUTH_CONTAINER:-0}" = 0 ] && [ -z "$_WORKER_AUTH_SAVED_CONFIG" ]; then
        trap - EXIT
        [ -z "$current_trap" ] || eval "$current_trap"
    fi
    return "$failed"
}
