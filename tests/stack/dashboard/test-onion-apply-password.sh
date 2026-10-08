# shellcheck shell=bash
: "${STACK_SUITE:?is unset: this file is a tests/stack/run.sh fragment, not a script — run tests/stack/run.sh}"
echo "== black-box: onion password dry-run refusal and cancelled apply =="
# Manual QA must distinguish a read-only validation failure from normal apply, which writes
# a generated password before asking for confirmation. Drive the real CLI with Docker stubbed.
onion_apply_password_cases() {
    local SANDBOX="$SANDBOX/onion-apply-password" C CTRL_LOG WALLET
    local out rc generated before_config before_env
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
    before_config=$(cat "$C/config.json")
    before_env=$(cat "$C/.env")
    : >"$CTRL_LOG"
    out=$(cd "$C" && DOCKER_LOG="$CTRL_LOG" PATH="$C/bin:$PATH" ./pithead apply --dry-run 2>&1)
    rc=$?
    assert_rc "onion without auth fails dry-run validation" "$rc" 1
    assert_contains "dry-run names missing onion password" "$out" "dashboard.onion.enabled is true but dashboard.auth.password is empty"
    assert_eq "dry-run leaves candidate byte-identical" "$(cat "$C/config.json")" "$before_config"
    assert_eq "dry-run leaves rendered environment byte-identical" "$(cat "$C/.env")" "$before_env"
    assert_eq "dry-run never calls Docker" "$(cat "$CTRL_LOG")" ""

    out=$(cd "$C" && printf 'n\n' | DOCKER_LOG="$CTRL_LOG" PATH="$C/bin:$PATH" ./pithead apply 2>&1)
    rc=$?
    assert_rc "normal onion apply can be cancelled" "$rc" 0
    generated=$(jq -r '.dashboard.auth.password // ""' "$C/config.json")
    assert_eq "cancelled apply retains a 32-character generated password" "${#generated}" 32
    assert_contains "normal apply reports password generation" "$out" "generated one and saved it to config.json"
    assert_contains "normal apply previews disruptive changes" "$out" "Some of the changes above (⚠) are disruptive."
    assert_contains "normal apply reports cancellation" "$out" "Apply cancelled."
    assert_eq "cancelled apply leaves rendered environment byte-identical" "$(cat "$C/.env")" "$before_env"
    assert_not_contains "cancelled apply never recreates containers" "$(cat "$CTRL_LOG")" "compose up"
    assert_not_contains "cancelled apply never stops containers" "$(cat "$CTRL_LOG")" "compose stop"
    # Restoring the candidate baseline is necessary: cancellation did not undo generation.
    cp "$C/baseline" "$C/config.json"
    assert_eq "candidate baseline restoration removes generated credentials" "$(cat "$C/config.json")" "$before_config"
}
onion_apply_password_cases
