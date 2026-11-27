# shellcheck shell=bash
# Shared control fixtures. Existing configs and spool contents belong to the ordered battery;
# fresh fragment processes seed the same applied mini-pool baseline without predecessor tests.
# shellcheck disable=SC2034 # globals consumed by sourced control fragments
ensure_control_fixture() {
    build_control_sandbox
    [ -f "$C/.env" ] || seed_control_env
    REQS="$C/data/control/requests"
    RESULTS="$C/data/control/results"
    STAGED="$C/data/control/staged"
    AUDIT="$C/data/control/audit/control.log"
    MASKED="$C/data/control/masked/config.json"
    UUID3="33333333-3333-4333-8333-333333333333"
    UUID5="55555555-5555-4555-8555-555555555555"
    if [ ! -f "$C/config.json" ]; then
        control_config mini
        (cd "$C" && DOCKER_LOG="$CTRL_LOG" PATH="$C/bin:$PATH" ./pithead apply -y >/dev/null 2>&1) || {
            printf 'control fixture: initial apply failed\n' >&2
            exit 1
        }
    fi
}

gate_try() { # <candidate-json-file> [confirm-token] [approval-json] — preview then commit via the spool
    # Second arg: a typed "APPLY", so a PERIMETER case can prove refusal EVEN WITH a valid token.
    # Third: the approval ENVELOPE (2026-09-13 perimeter audit). Without one, every case here proved only that a
    # TOKEN-LESS commit is refused — and a self-written envelope walked past four (the container
    # writes the spool: its own actor, APPLY and suffix). test-control-perimeter-tier3.sh sends them.
    jq --arg id "$UUID5" '{id:$id,action:"preview",actor:"admin",config:.}' "$1" >"$REQS/$UUID5.json"
    run_pending >/dev/null
    jq -n --arg id "$UUID5" --arg c "${2:-}" --argjson a "${3:-null}" \
        '{id:$id,action:"commit",actor:"admin"} + (if $c == "" then {} else {confirm:$c} end)
         + (if $a == null then {} else {approval:$a} end)' >"$REQS/$UUID5.json"
    run_pending >/dev/null
}
