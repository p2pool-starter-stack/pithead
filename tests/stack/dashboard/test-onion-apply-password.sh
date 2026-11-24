# shellcheck shell=bash
: "${STACK_SUITE:?is unset: this file is a tests/stack/run.sh fragment, not a script — run tests/stack/run.sh}"
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

echo "== unit: log API Caddy routes and dashboard.mode wiring (issue 3978) =="
build_val_sandbox
LAW_HASH="$(printf '%s' '$2y$14$UNITTESTbcrypthashvalue000000000000000000000000000000' | openssl base64 -A)"
# shellcheck disable=SC1090
LAW_CADDY="$(
    cd "$SANDBOX" && source "$STACK" 2>/dev/null
    set +e
    DASHBOARD_SECURE=true HOST_IP=box.lan DASHBOARD_AUTH_USER=admin DASHBOARD_AUTH_HASH_B64="$LAW_HASH" \
        DASHBOARD_ONION_ENABLED=true DASHBOARD_ONION=abcd234onionname.onion NETWORK_PREFIX=172.28.0 generate_caddyfile >/dev/null 2>&1
    cat Caddyfile
)"
LAW_LAN="${LAW_CADDY%%http://172.28.0.1 \{*}"
LAW_ONION="${LAW_CADDY#"$LAW_LAN"}"
assert_contains "log routes stream unbuffered on the LAN site" "$LAW_LAN" "@logs path /api/logs/*"
assert_contains "log routes disable response buffering on the LAN site" "$LAW_LAN" "flush_interval -1"
assert_not_contains "no buffering override on the onion sites" "$LAW_ONION" "flush_interval"
assert_eq "both onion sites answer the log routes with 404" "$(printf '%s\n' "$LAW_ONION" | grep -c 'respond @logs 404')" "2"
assert_not_contains "the LAN site never hides the log routes" "$LAW_LAN" "respond @logs"

law_apply() {
    seed_env
    printf '{ "monero": {"mode":"local","wallet_address":"%s","node_username":"u","node_password":"p"}, "tari":{"wallet_address":"%s"}, "p2pool":{"pool":"main"}, "dashboard":{"secure":true,"host":"box.lan"%s} }\n' "$WALLET" "$VALID_TARI" "$1" >"$V/config.json"
    LAW_OUT="$(cd "$V" && PATH="$V/bin:$PATH" ./pithead apply -y 2>&1)"
    LAW_RC=$?
}
law_env() { run_sourced "$V" env_get_file "$V/.env" "$1"; }

law_apply ""
assert_rc "apply without dashboard.mode succeeds" "$LAW_RC" "0"
assert_eq "absent dashboard.mode renders dashboard" "$(law_env DASHBOARD_MODE)" "dashboard"
assert_eq "the host allowlist reaches the dashboard comma-separated" "$(law_env PITHEAD_DIAG_CONTAINERS)" \
    "$(run_sourced "$V" eval 'printf %s "${PITHEAD_DIAG_CONTAINERS// /,}"')"
for law_mode in api both; do
    law_apply ",\"mode\":\"$law_mode\""
    assert_rc "dashboard.mode $law_mode accepted" "$LAW_RC" "0"
    assert_eq "dashboard.mode $law_mode rendered" "$(law_env DASHBOARD_MODE)" "$law_mode"
done
law_apply ',"mode":"headless"'
assert_rc "invalid dashboard.mode rejected" "$LAW_RC" "1"
assert_contains "invalid dashboard.mode message" "$LAW_OUT" "dashboard.mode must be"
