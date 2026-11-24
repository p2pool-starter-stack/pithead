# shellcheck shell=bash
: "${STACK_SUITE:?is unset: this file is a tests/stack/run.sh fragment, not a script — run tests/stack/run.sh}"
echo "== dashboard.auth.password verdict is the same in every locale (#4453) =="
build_val_sandbox
cp "$ROOT/docker-compose.yml" "$V/docker-compose.yml"
dash_pw_apply() {
    seed_env
    jq -n --arg w "$WALLET" --arg t "$VALID_TARI" --arg p "$2" --argjson o "$([ -n "${3:-}" ] && echo true || echo false)" \
        '{monero:{mode:"local",wallet_address:$w,node_username:"u",node_password:"p"},tari:{wallet_address:$t},p2pool:{pool:"main"},dashboard:{secure:true,host:"box.lan",onion:{enabled:$o},auth:{username:"admin",password:$p}}}' >"$V/config.json"
    (cd "$V" && LC_ALL="$1" PATH="$V/bin:$PATH" ./pithead apply -y 2>&1)
}
dash_pw_cases() {
    local loc="$1"
    echo "-- LC_ALL=$loc --"
    out=$(dash_pw_apply "$loc" "pässwörd-12345")
    assert_not_contains "non-ASCII password is accepted" "$out" "dashboard.auth.password must be"
    out=$(dash_pw_apply "$loc" "$(printf 'ä%.0s' $(seq 36))")
    assert_not_contains "36 two-byte characters are accepted" "$out" "dashboard.auth.password must be"
    out=$(dash_pw_apply "$loc" "ääääääx")
    assert_contains "7 characters are rejected, whatever their byte count" "$out" "dashboard.auth.password must be 8–128 characters with no control characters or double-quotes"
    out=$(dash_pw_apply "$loc" "$(printf 'a%.0s' $(seq 129))")
    assert_contains "129 characters are rejected" "$out" "dashboard.auth.password must be 8–128 characters with no control characters or double-quotes"
    out=$(dash_pw_apply "$loc" 'pässwörd-"12345')
    assert_contains "a double-quote is rejected" "$out" "dashboard.auth.password must be 8–128 characters with no control characters or double-quotes"
    out=$(dash_pw_apply "$loc" "$(printf 'ä%.0s' $(seq 16))" onion)
    assert_contains "onion: 16 identical two-byte characters are a repeated character" "$out" "single repeated character"
}
dash_pw_cases C
dash_pw_cases C.UTF-8

echo "== black-box: onion password dry-run refusal and cancelled apply =="
# Manual QA must distinguish a read-only validation failure from normal apply, which writes
# a generated password before asking for confirmation. Drive the real CLI with Docker stubbed.
onion_apply_password_cases() {
    # shellcheck disable=SC2034 # WALLET is consumed by shared control fixture helpers.
    local SANDBOX="$SANDBOX/onion-apply-password" C CTRL_LOG WALLET
    local out rc generated
    build_control_sandbox
    seed_control_env
    control_config mini
    cp "$ROOT/VERSION" "$C/VERSION"
    # Render the complete applied baseline so the preview contains no payout changes.
    out=$(cd "$C" && PATH="$C/bin:$PATH" run_sourced "$C" eval 'parse_and_validate_config; load_preserved_state; resolve_dashboard_host; DEPLOYMENT_COMPLETED=true; render_env .env' 2>&1)
    assert_rc "onion apply fixture renders its baseline" "$?" 0
    jq 'del(.dashboard.auth) | .dashboard.onion.enabled=true' "$C/config.json" >"$C/candidate"
    mv "$C/candidate" "$C/config.json"
    cp "$C/config.json" "$C/baseline"
    cp "$C/.env" "$C/env-baseline"
    : >"$CTRL_LOG"
    out=$(cd "$C" && DOCKER_LOG="$CTRL_LOG" PATH="$C/bin:$PATH" ./pithead apply --dry-run 2>&1)
    rc=$?
    assert_rc "onion without auth fails dry-run validation" "$rc" 1
    assert_contains "dry-run names missing onion password" "$out" "dashboard.onion.enabled is true but dashboard.auth.password is empty"
    assert_eq "dry-run leaves candidate byte-identical" "$(
        cmp -s "$C/config.json" "$C/baseline"
        echo $?
    )" 0
    assert_eq "dry-run leaves rendered environment byte-identical" "$(
        cmp -s "$C/.env" "$C/env-baseline"
        echo $?
    )" 0
    assert_eq "dry-run never calls Docker" "$(cat "$CTRL_LOG")" ""

    out=$(cd "$C" && printf 'n\n' | DOCKER_LOG="$CTRL_LOG" PATH="$C/bin:$PATH" ./pithead apply 2>&1)
    rc=$?
    assert_rc "normal onion apply can be cancelled" "$rc" 0
    generated=$(jq -r '.dashboard.auth.password // ""' "$C/config.json")
    assert_eq "cancelled apply retains a 32-character generated password" "${#generated}" 32
    assert_contains "normal apply reports password generation" "$out" "generated one and saved it to config.json"
    assert_contains "normal apply previews disruptive changes" "$out" "Some of the changes above (⚠) are disruptive."
    assert_contains "normal apply reports cancellation" "$out" "Apply cancelled."
    assert_eq "cancelled apply leaves rendered environment byte-identical" "$(
        cmp -s "$C/.env" "$C/env-baseline"
        echo $?
    )" 0
    assert_not_contains "cancelled apply never recreates containers" "$(cat "$CTRL_LOG")" "compose up"
    assert_not_contains "cancelled apply never stops containers" "$(cat "$CTRL_LOG")" "compose stop"
    # Restoring the candidate baseline is necessary: cancellation did not undo generation.
    cp "$C/baseline" "$C/config.json"
    assert_eq "candidate baseline restoration removes generated credentials" "$(
        cmp -s "$C/config.json" "$C/baseline"
        echo $?
    )" 0
}
onion_apply_password_cases
