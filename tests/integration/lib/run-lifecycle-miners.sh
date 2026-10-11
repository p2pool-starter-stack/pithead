# shellcheck shell=bash
# Reconnection/share assertions for every lifecycle mutation that restarts the proxy.
: "${INTEGRATION_RUN_SUITE:?source via the suite runner}"
lifecycle_proxy_started() { rx "docker inspect --format '{{.State.StartedAt}}' xmrig-proxy" 2>/dev/null; }
lifecycle_proxy_workers() {
    rx "timeout --kill-after=2 15 docker compose exec -T dashboard python3 - <<'PY'
import json, os
from mining_dashboard.helper.http import bounded_get
r=bounded_get('http://{}:{}/1/workers'.format(os.environ['PROXY_HOST'], os.environ['PROXY_API_PORT']),
              headers={'Authorization': 'Bearer '+os.environ['PROXY_AUTH_TOKEN']}, timeout=5)
r.raise_for_status()
rows=r.json()['workers']
assert type(rows) is list
for row in rows:
    assert type(row) is list and len(row) >= 4 and type(row[0]) is str
    assert all(type(v) is int and v >= 0 for v in row[2:4])
print(json.dumps(rows))
PY"
}
lifecycle_worker_set() {
    lifecycle_proxy_workers | jq -ce '[.[] | select(.[2] >= 1) | .[0]] | unique'
}
lifecycle_miners_returned() { # <expected JSON names> <require accepted>
    local rows
    rows=$(lifecycle_proxy_workers) || return 1
    # Read the live proxy, never dashboard cached pre-restart counts. New counters start at zero.
    jq -e --argjson names "$1" --argjson shares "$2" '
        . as $workers | (type == "array") and
        all($names[]; . as $name | any($workers[];
            .[0] == $name and .[2] >= 1 and (if $shares then .[3] >= 1 else true end)))' <<<"$rows" >/dev/null
}
lifecycle_mining_load() {
    [ -n "${LIFECYCLE_MINER_STATE:-}" ] && [ -e "$LIFECYCLE_MINER_STATE" ] || return 0
    LIFECYCLE_MINER_NAMES=$(jq -ce '.names | select(type == "array")' "$LIFECYCLE_MINER_STATE") || return 1
    LIFECYCLE_MINER_STOPPED=$(jq -er '.stopped | select(. == 0 or . == 1)' "$LIFECYCLE_MINER_STATE")
}
lifecycle_mining_save() {
    [ -n "${LIFECYCLE_MINER_STATE:-}" ] || return 0
    local temporary
    temporary=$(mktemp "${LIFECYCLE_MINER_STATE}.XXXXXX") || return 1
    if ! jq -nc --argjson names "$LIFECYCLE_MINER_NAMES" --argjson stopped "${LIFECYCLE_MINER_STOPPED:-0}" '{names:$names,stopped:$stopped}' >"$temporary" ||
        ! mv "$temporary" "$LIFECYCLE_MINER_STATE"; then
        rm -f "$temporary"
        return 1
    fi
}
lifecycle_mining_step() { # <description> <command> [args]
    local label=$1 before after names end rc=0
    shift
    if [ "${SKIP_MINING_ASSERTS:-0}" = 1 ]; then
        "$@"
        return $?
    fi
    lifecycle_mining_load || return 1
    if [ "${LIFECYCLE_MINER_STOPPED:-0}" = 1 ]; then
        before=absent
        names=${LIFECYCLE_MINER_NAMES:-'[]'}
    else
        before=$(lifecycle_proxy_started) && names=$(lifecycle_worker_set) || {
            it_fail "$label mining precondition" "proxy inspection or live worker set unreadable"
            return 1
        }
    fi
    # An intentional down/up span retains the last live set instead of proving an empty set.
    [ "$names" != '[]' ] || {
        it_fail "$label mining precondition" "no online workers before lifecycle mutation"
        return 1
    }
    LIFECYCLE_MINER_NAMES=$names
    lifecycle_mining_save || return 1
    "$@" || rc=$?
    [ "$rc" = 0 ] || return "$rc"
    case "$label" in down | uninstall)
        LIFECYCLE_MINER_STOPPED=1
        lifecycle_mining_save
        return $?
        ;;
    esac
    if [ "${LIFECYCLE_MINER_STOPPED:-0}" = 1 ] && [ "$label" = restore ]; then return 0; fi
    after=$(lifecycle_proxy_started) || {
        it_fail "$label proxy restarts" "proxy inspection failed after a live-returning step"
        return 1
    }
    LIFECYCLE_MINER_STOPPED=0
    lifecycle_mining_save || return 1
    [ "$after" != "$before" ] || return 0
    end=$((SECONDS + ${BOUND_RECONNECT:-480}))
    until lifecycle_miners_returned "$names" false; do
        [ "$SECONDS" -lt "$end" ] || {
            it_fail "$label workers reconnect" "worker set did not return within BOUND_RECONNECT"
            return 1
        }
        sleep 5
    done
    end=$((SECONDS + 600))
    until lifecycle_miners_returned "$names" true; do
        [ "$SECONDS" -lt "$end" ] || {
            it_fail "$label workers accept shares" "a worker did not accept a post-restart share within 600 seconds"
            return 1
        }
        sleep 5
    done
    it_pass "$label workers reconnect and accept post-restart shares (#3375)"
}

# The shared test command catches each mutation inside composite lifecycle legs as well.
lifecycle_raw_pithead() { rx "$IT_PITHEAD $*"; }
pithead() {
    case "${LIFECYCLE_MINING_ACTIVE:-0}:$1" in
    1:restart | 1:apply | 1:up | 1:down | 1:backup | 1:restore | 1:setup | 1:uninstall)
        lifecycle_mining_step "$1" lifecycle_raw_pithead "$@"
        ;;
    *) lifecycle_raw_pithead "$@" ;;
    esac
}
