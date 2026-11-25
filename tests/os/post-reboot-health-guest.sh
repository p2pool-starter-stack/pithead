#!/usr/bin/env bash
cd "${POH_DIR:-/data/pithead}" || exit 2
if ! command -v docker >/dev/null 2>&1 && command -v podman >/dev/null 2>&1; then
    poh_bin=$(mktemp -d)
    ln -s "$(command -v podman)" "$poh_bin/docker"
    export PATH="$poh_bin:$PATH"
fi
IT_FAIL=0
it_pass() { printf 'POH PASS %s\n' "$1"; }
it_fail() {
    IT_FAIL=$((IT_FAIL + 1))
    printf 'POH FAIL %s :: %s\n' "$1" "${2:-}"
}
it_skip_leg() { printf 'POH SKIP %s :: %s\n' "$1" "${2:-}"; }
it_step() { :; }
it_warn() { :; }
redact() { cat; }
now_s() { date +%s; }
quote_arg() { printf '%q' "$1"; }
rx() { bash -c "$1"; }
api_state() { curl -fsS --max-time 10 http://127.0.0.1:8000/api/state 2>/dev/null; }
env_on_box() { bash -c 'source ./pithead && env_get_file .env "$1"' _ "$1"; }
wait_for() {
    local timeout="$1" interval="$2" deadline
    shift 3
    deadline=$(($(now_s) + timeout))
    while :; do
        "$@" && return 0
        [ "$(now_s)" -lt "$deadline" ] || return 1
        sleep "$interval"
    done
}

poh_settled() { ! grep -q ' starting$' <<<"$(poi_container_snapshot)"; }

poh_running_names() { poi_container_snapshot | cut -d' ' -f1 | grep -E "${POH_CONTAINER_RE:-.}" || true; }

poh_main() {
    local state missing
    case "${1:-}" in
    snapshot)
        state=$(api_state) && jq -e . >/dev/null 2>&1 <<<"$state" || return 1
        POI_WORKERS=$(jq -r '.workers[]? | select(.status == "online") | .name' <<<"$state" | sort -u)
        POI_FAILURES=$(poi_failures_24h)
        [ -n "$POI_FAILURES" ] || return 1
        printf 'POH_WORKERS=%s\nPOH_FAILURES=%s\nPOH_CONTAINERS=%s\n' "$(printf '%s' "$POI_WORKERS" | base64 | tr -d '\n')" \
            "$POI_FAILURES" "$(poh_running_names | base64 | tr -d '\n')"
        ;;
    verify)
        POI_WORKERS=$(printf '%s' "${POH_WORKERS:-}" | base64 -d)
        POI_FAILURES="${POH_FAILURES:-}"
        wait_for "${POH_SETTLE_S:-300}" 10 "containers settled" poh_settled || true
        missing=$(comm -23 <(printf '%s' "${POH_CONTAINERS:-}" | base64 -d | sed '/^$/d' | sort -u) <(poh_running_names | sort -u) | tr '\n' ' ')
        if [ -z "${POH_CONTAINERS:-}" ]; then
            it_fail "${POH_LABEL:-post-reboot}: every container running before the step is running again" "no baseline"
        elif [ -n "$missing" ]; then
            it_fail "${POH_LABEL:-post-reboot}: every container running before the step is running again" "not running: $missing"
        else
            it_pass "${POH_LABEL:-post-reboot}: every container running before the step is running again"
        fi
        post_op_invariants "${POH_LABEL:-post-reboot}"
        printf 'POH DONE\n'
        [ "$IT_FAIL" -eq 0 ]
        ;;
    *) return 2 ;;
    esac
}
