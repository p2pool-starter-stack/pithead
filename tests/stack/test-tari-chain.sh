# shellcheck shell=bash
: "${STACK_SUITE:?is unset: this file is a tests/stack/run.sh fragment, not a script — run tests/stack/run.sh}"
# Reuses test-doctor.sh's DRBIN stubs (curl prints CURL_BODY) and test-tor-network.sh's apply
# sandbox ($V, seed_env): both fragments run before this one.

echo "== unit: doctor + status Tari chain verdict (#2464) =="
# The verdict is the dashboard's (/api/state .tari.health): amber WARNs, red FAILs doctor, and status
# prints the same line without touching its exit code. A READY merge-mine channel is not consulted.
tari_state() { # <level> <reasons-json-array> <advice>
    printf '{"tari":{"connected":true,"health":{"level":"%s","reasons":%s,"advice":"%s"}}}' "$1" "$2" "$3"
}
RED="$(tari_state red '["tip 342574 unchanged for 31 min","0 peer connections for 31 min"]' "restart the Tari node")"
out="$(CURL_BODY="$RED" PATH="$DRBIN:$PATH" run_sourced "$SANDBOX" check_tari_chain 2>&1)"
assert_contains "tari chain: red -> doctor FAIL names the verdict" "$out" "NOT following the chain"
assert_contains "tari chain: red -> doctor carries every reason" "$out" "tip 342574 unchanged for 31 min; 0 peer connections for 31 min"
assert_contains "tari chain: red -> doctor names the next step" "$out" "next: restart the Tari node"
tari_chain_fail_count() { DR_FAIL=0 && check_tari_chain >/dev/null 2>&1 && echo "$DR_FAIL"; }
assert_eq "tari chain: red counts as a doctor failure" \
    "$(CURL_BODY="$RED" PATH="$DRBIN:$PATH" run_sourced "$SANDBOX" tari_chain_fail_count)" "1"
AMBER="$(tari_state amber '["0 peer connections for 12 min"]' "restart the Tari node")"
out="$(CURL_BODY="$AMBER" PATH="$DRBIN:$PATH" run_sourced "$SANDBOX" check_tari_chain 2>&1)"
assert_contains "tari chain: amber -> doctor WARN with the reason" "$out" "may be stalling: 0 peer connections for 12 min"
out="$(CURL_BODY="$(tari_state green '[]' '')" PATH="$DRBIN:$PATH" run_sourced "$SANDBOX" check_tari_chain 2>&1)"
assert_contains "tari chain: green -> OK" "$out" "follows the chain"
out="$(CURL_BODY='{"tari":{"connected":true}}' PATH="$DRBIN:$PATH" run_sourced "$SANDBOX" check_tari_chain 2>&1)"
assert_eq "tari chain: no verdict (Tari off, loop not run) -> silent" "$out" ""
out="$(CURL_RC=7 PATH="$DRBIN:$PATH" run_sourced "$SANDBOX" check_tari_chain 2>&1)"
assert_eq "tari chain: dashboard not answering -> silent (check_dashboard_answers owns that)" "$out" ""

out="$(CURL_BODY="$RED" PATH="$DRBIN:$PATH" run_sourced "$SANDBOX" tari_chain_status_line 2>&1)"
assert_contains "tari chain: status prints the red line" "$out" "tari chain    NOT following the chain: tip 342574"
out="$(CURL_BODY="$AMBER" PATH="$DRBIN:$PATH" run_sourced "$SANDBOX" tari_chain_status_line 2>&1)"
assert_contains "tari chain: status prints the amber line" "$out" "0 peer connections for 12 min"

echo "== black-box: tari.auto_restart / tari.explorer_url render to .env (#2464) =="
seed_env
printf '{ "monero": {"mode":"local","wallet_address":"%s","node_username":"u","node_password":"p"}, "tari":{"wallet_address":"'"$VALID_TARI"'"}, "p2pool":{"pool":"main"}, "dashboard":{"secure":true,"host":"box.lan"} }\n' "$WALLET" >"$V/config.json"
(cd "$V" && PATH="$V/bin:$PATH" ./pithead apply -y >/dev/null 2>&1)
assert_eq "tari.auto_restart defaults to on" "$(run_sourced "$V" env_get_file "$V/.env" TARI_AUTO_RESTART)" "true"
assert_eq "tari.explorer_url defaults to the text explorer" "$(run_sourced "$V" env_get_file "$V/.env" TARI_EXPLORER_URL)" "https://textexplore.tari.com/?json"
seed_env
printf '{ "monero": {"mode":"local","wallet_address":"%s","node_username":"u","node_password":"p"}, "tari":{"wallet_address":"'"$VALID_TARI"'","auto_restart":false,"explorer_url":""}, "p2pool":{"pool":"main"}, "dashboard":{"secure":true,"host":"box.lan"} }\n' "$WALLET" >"$V/config.json"
(cd "$V" && PATH="$V/bin:$PATH" ./pithead apply -y >/dev/null 2>&1)
assert_eq "tari.auto_restart:false renders false" "$(run_sourced "$V" env_get_file "$V/.env" TARI_AUTO_RESTART)" "false"
assert_eq "a blank tari.explorer_url renders blank (reference off)" "$(run_sourced "$V" env_get_file "$V/.env" TARI_EXPLORER_URL)" ""
