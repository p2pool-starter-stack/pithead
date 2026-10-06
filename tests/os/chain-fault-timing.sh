#!/usr/bin/env bash
# Debounce proof for the post-commit Tari fault leg. Never change the guest's policy.

chain_fault_down_after() {
    local env_json value
    # Inspect the running container, not .env: an override must be what the monitor uses.
    env_json=$(_ssh "id=\$(podman ps -q --filter label=com.docker.compose.service=dashboard | head -n1)
[ -n \"\$id\" ] && podman inspect --format '{{json .Config.Env}}' \"\$id\"" 2>/dev/null) || return 1
    value=$(printf '%s' "$env_json" | jq -er '
        if type != "array" then error("environment is not an array") else
        map(select(startswith("TARI_NODE_DOWN_AFTER_SEC="))) |
        if length == 0 then "900"
        elif length == 1 then .[0] | ltrimstr("TARI_NODE_DOWN_AFTER_SEC=")
        else error("duplicate debounce") end end') || return 1
    # Bound the test, rejecting unsupported policy instead of silently clamping it.
    [[ "$value" =~ ^[0-9]{1,4}$ ]] || return 1
    value=$((10#$value))
    [ "$value" -ge 1 ] && [ "$value" -le 3600 ] || return 1
    printf '%s\n' "$value"
}

# Monotonic elapsed time keeps wall-clock corrections out of the fault deadline.
chain_fault_now() { python3 -I -c 'import time; print(int(time.monotonic()))'; }

# Check status and bounded decimal output before shell arithmetic (including leading zeros).
chain_fault_clock_read() {
    local now
    now=$(chain_fault_now) || return 1
    [[ "$now" =~ ^[0-9]{1,12}$ ]] || return 1
    printf '%s\n' "$((10#$now))"
}

chain_fault_wait_badge() { # <debounce-seconds> <stop-started>
    local down_after="$1" started="$2" previous="$2" now elapsed early_seen=0 unreadable_streak=0 timely=0 read_rc sample
    # state belongs to the caller, so its final badge/evidence assertion reads this sample.
    # shellcheck disable=SC2034
    while :; do
        read_rc=0
        state=$(chain_fault_state) || read_rc=$?
        if ! now=$(chain_fault_clock_read) || [ "$now" -lt "$previous" ]; then
            bad "post-commit $CHAIN_FAULT_SERVICE fault: monotonic clock failed or moved backward — timing was not proved; continuing to recovery"
            return 1
        fi
        previous=$now
        elapsed=$((now - started))
        # Report only the badge verdict or read error; /api/state can contain secrets.
        sample="elapsed=${elapsed}s read_rc=$read_rc"
        [ "$elapsed" -le $((down_after + 180)) ] || break
        if [ "$elapsed" -lt "$down_after" ]; then
            if [ "$read_rc" = 0 ] && chain_fault_dashboard_verdict "$state" recovered; then
                early_seen=1
                unreadable_streak=0
            elif [ "$read_rc" = 0 ] && chain_fault_dashboard_verdict "$state" faulted; then
                bad "post-commit $CHAIN_FAULT_SERVICE fault: Tari DOWN appeared before the ${down_after}s debounce ($sample; dashboard badge: Tari DOWN); continuing to recovery"
                return 1
            else
                unreadable_streak=$((unreadable_streak + 1))
                if [ "$read_rc" = 0 ]; then sample+="; invalid JSON or badge list"; fi
                if [ "$unreadable_streak" -gt 3 ]; then
                    bad "post-commit $CHAIN_FAULT_SERVICE fault: dashboard unreadable for $unreadable_streak consecutive pre-debounce samples ($sample); continuing to recovery"
                    return 1
                fi
            fi
        elif [ "$read_rc" = 0 ] && chain_fault_dashboard_verdict "$state" faulted; then
            timely=1
            break
        fi
        [ "$elapsed" -lt $((down_after + 180)) ] || break
        sleep 5
    done
    if [ "$early_seen" = 1 ]; then
        ok "post-commit $CHAIN_FAULT_SERVICE fault: no Tari DOWN badge before the ${down_after}s debounce"
    else
        bad "post-commit $CHAIN_FAULT_SERVICE fault: no readable pre-debounce sample was observed ($sample)"
    fi
    [ "$timely" = 1 ]
}
