# shellcheck shell=bash
: "${STACK_SUITE:?source through tests/stack/run.sh}"
echo "== unit: donation config keys (#4309) =="
assert_eq "reference donation block" "$(jq -c .donation "$ROOT/config.reference.json")" '{"enabled":false,"percent":0,"tor":true}'
DN="$SANDBOX/donation-config"
mkdir -p "$DN"
cp "$ROOT/VERSION" "$DN/VERSION"
donation_case() {
    jq -n --arg w "$VALID_PRIMARY" --argjson d "$1" \
        '{monero:{wallet_address:$w,node_username:"u",node_password:"p"},tari:{mode:"off"},dashboard:{secure:false},donation:$d}' >"$DN/config.json"
    rm -f "$DN/.env"
    out=$(run_sourced "$DN" eval "PITHEAD_DRY_RUN=1; parse_and_validate_config${2:+ && load_preserved_state && render_env}" 2>&1)
    rc=$?
}
for bad_pct in '{"enabled":true,"percent":0}' '{"enabled":true,"percent":0.05}' '{"enabled":true,"percent":10.5}' '{"enabled":true,"percent":"5"}' '{"enabled":true,"percent":true}' '{"enabled":true,"percent":null}' '{"enabled":false,"percent":11}'; do
    donation_case "$bad_pct"
    assert_rc "donation $bad_pct rejected" "$rc" 1
    assert_contains "donation $bad_pct names donation.percent" "$out" "donation.percent"
done
for good_pct in '{"enabled":true,"percent":0.1}' '{"enabled":true,"percent":0.25}' '{"enabled":true,"percent":2.5}' '{"enabled":true,"percent":1}' '{"enabled":true,"percent":10}' '{"enabled":false,"percent":0}' '{}'; do
    donation_case "$good_pct"
    assert_rc "donation $good_pct accepted" "$rc" 0
done
donation_case '{"enabled":"yes"}'
assert_rc "non-boolean donation.enabled rejected" "$rc" 1
assert_contains "donation.enabled message" "$out" "donation.enabled"
donation_case '{"tor":1}'
assert_rc "non-boolean donation.tor rejected" "$rc" 1
assert_contains "donation.tor message" "$out" "donation.tor"
donation_case '{}' render
assert_rc "default donation renders" "$rc" 0
for row in DONATION_ENABLED=false DONATION_PERCENT=0 DONATION_TOR_ENABLED=true; do
    assert_eq "default render: $row" "$(grep -c "^$row\$" "$DN/.env")" 1
done
donation_case '{"enabled":true,"percent":2.5,"tor":false}' render
for row in DONATION_ENABLED=true DONATION_PERCENT=2.5 DONATION_TOR_ENABLED=false; do
    assert_eq "explicit render: $row" "$(grep -c "^$row\$" "$DN/.env")" 1
done
unset -f donation_case
