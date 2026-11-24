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

poh_main() {
    case "${1:-}" in
    snapshot)
        post_op_begin
        printf 'POH_WORKERS=%s\nPOH_FAILURES=%s\n' "$(printf '%s' "$POI_WORKERS" | paste -sd, -)" "$POI_FAILURES"
        ;;
    verify)
        POI_WORKERS=$(printf '%s' "${POH_WORKERS:-}" | tr ',' '\n')
        POI_FAILURES="${POH_FAILURES:-}"
        post_op_invariants "${POH_LABEL:-post-reboot}"
        [ "$IT_FAIL" -eq 0 ]
        ;;
    *) return 2 ;;
    esac
}
