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
assert_contains "tari chain: green -> OK, claiming only what the verdict establishes" "$out" "no degraded signal confirmed"
assert_not_contains "tari chain: green does not claim peers or explorer agreement" "$out" "peers connected"
out="$(CURL_BODY="$(tari_state green '[]' '')" PATH="$DRBIN:$PATH" run_sourced "$SANDBOX" tari_chain_status_line 2>&1)"
assert_contains "tari chain: status prints the green line" "$out" "tari chain    no degraded signal confirmed"
out="$(CURL_BODY='{"tari":{"connected":true}}' PATH="$DRBIN:$PATH" run_sourced "$SANDBOX" check_tari_chain 2>&1)"
assert_eq "tari chain: no verdict (Tari off, loop not run) -> silent" "$out" ""
out="$(CURL_RC=7 PATH="$DRBIN:$PATH" run_sourced "$SANDBOX" check_tari_chain 2>&1)"
assert_eq "tari chain: dashboard not answering -> silent (check_dashboard_answers owns that)" "$out" ""

out="$(CURL_BODY="$RED" PATH="$DRBIN:$PATH" run_sourced "$SANDBOX" tari_chain_status_line 2>&1)"
assert_contains "tari chain: status prints the red line" "$out" "tari chain    NOT following the chain: tip 342574"
out="$(CURL_BODY="$AMBER" PATH="$DRBIN:$PATH" run_sourced "$SANDBOX" tari_chain_status_line 2>&1)"
assert_contains "tari chain: status prints the amber line" "$out" "0 peer connections for 12 min"

echo "== black-box: tari.explorer_url renders to .env (#2464) =="
seed_env
printf '{ "monero": {"mode":"local","wallet_address":"%s","node_username":"u","node_password":"p"}, "tari":{"wallet_address":"'"$VALID_TARI"'"}, "p2pool":{"pool":"main"}, "dashboard":{"secure":true,"host":"box.lan"} }\n' "$WALLET" >"$V/config.json"
(cd "$V" && PATH="$V/bin:$PATH" ./pithead apply -y >/dev/null 2>&1)
assert_eq "tari.explorer_url defaults to the text explorer" "$(run_sourced "$V" env_get_file "$V/.env" TARI_EXPLORER_URL)" "https://textexplore.tari.com/?json"
seed_env
printf '{ "monero": {"mode":"local","wallet_address":"%s","node_username":"u","node_password":"p"}, "tari":{"wallet_address":"'"$VALID_TARI"'","explorer_url":""}, "p2pool":{"pool":"main"}, "dashboard":{"secure":true,"host":"box.lan"} }\n' "$WALLET" >"$V/config.json"
(cd "$V" && PATH="$V/bin:$PATH" ./pithead apply -y >/dev/null 2>&1)
assert_eq "no automatic-restart setting renders: detection only (#2827 has remediation)" "$(grep -c '^TARI_AUTO_RESTART=' "$V/.env")" "0"
assert_eq "a blank tari.explorer_url renders blank (reference off)" "$(run_sourced "$V" env_get_file "$V/.env" TARI_EXPLORER_URL)" ""

# Under pithead's own `set -eo pipefail` a dashboard that does not answer must not abort status: the
# verdict line is extra, and #2464 must not change status's exit code (CI caught curl's exit 7).
tari_status_strict() { set -eo pipefail && tari_chain_status_line && echo "rc=0"; }
assert_eq "tari chain: dashboard down under pipefail leaves status's line empty, rc 0" \
    "$(CURL_RC=7 PATH="$DRBIN:$PATH" run_sourced "$SANDBOX" tari_status_strict 2>&1)" "rc=0"

echo "== unit: support bundle masks the Tari explorer URL in config.masked.json (#2464) =="
# Synthetic, credential-bearing: userinfo and a path token must not reach the bundle's config copy.
TARI_BUNDLE_CFG='{"tari":{"mode":"local","explorer_url":"https://user:OLDSECRET31@explorer.invalid/OLDSECRET32/?json"},"xvb":{"url":"https://xvb.invalid"}}'
tari_masked="$(printf '%s' "$TARI_BUNDLE_CFG" | run_sourced "$SANDBOX" bundle_mask_config 2>&1)"
assert_not_contains "bundle config: explorer URL userinfo is gone" "$tari_masked" "OLDSECRET31"
assert_not_contains "bundle config: explorer URL path token is gone" "$tari_masked" "OLDSECRET32"
assert_eq "bundle config: explorer URL becomes the secret sentinel" "$(printf '%s' "$tari_masked" | jq -c '.tari.explorer_url')" '{"__secret__":true}'
assert_eq "bundle config: the rest of the config survives" "$(printf '%s' "$tari_masked" | jq -r '.tari.mode + " " + .xvb.url')" "local https://xvb.invalid"
