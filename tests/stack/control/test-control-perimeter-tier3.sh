# shellcheck shell=bash
: "${STACK_SUITE:?is unset: this file is a tests/stack/run.sh fragment, not a script — run tests/stack/run.sh}"
# Confirmed security-sensitive configuration commits (#1959).
# Each moved key is refused without a confirmation and applies with APPLY plus the approval
# envelope. The envelope is typo protection, not a second identity. This fragment follows
# test-control-add-only-ssrf.sh because it reuses gate_try() and $UUID5 from that domain.

# gate_try() writes the request spool itself, from the $REQS it reads in the file that defines it;
# only the results path is read here.
RESULTS="$C/data/control/results"

# The envelope a compromised container writes for itself: no operator typed any of it.
SELF_ENVELOPE='{"payout_suffixes":{}}'
# A second checksum-valid mainnet primary (the Monero project's legacy donation address).
ATTACKER_WALLET="44AFFq5kSiGBoZ4NMDwYtN18obc8AemS33DBLWs3H7otXft3XjrpDtQGv7SqSsaBYBb98uNbr2VBBEt7f2wfn3RVGQBEP3A"

echo "== black-box: perimeter settings require confirmation and then apply (#1959) =="
# Baseline from the host CLI, never the gate, so what the cases below protect is real.
jq -n --arg w "$WALLET" \
    '{monero:{mode:"local",wallet_address:$w,node_username:"u",node_password:"p"},
    tari:{wallet_address:"'"$VALID_TARI"'"}, p2pool:{pool:"nano",stratum_password:"s3cretpw"},
    dashboard:{secure:true,host:"box.lan",auth:{username:"admin",password:"a control passphrase"},
               control:{enabled:true}}}' >"$C/config.json"
(cd "$C" && DOCKER_LOG="$CTRL_LOG" PATH="$C/bin:$PATH" ./pithead apply -y >/dev/null 2>&1)
assert_contains "perimeter baseline applied from the host CLI" "$(cat "$C/.env")" "MONERO_WALLET_ADDRESS=$WALLET"
# The wallet-change alarm baseline lives in the dashboard DB. Bundle its data-dir move with the
# payout change below and pin what actually happens to that row: an operator-pinned path is left
# alone (#455), so the baseline stays put rather than being carried (#2360).
LIVE_DASHBOARD_DIR="$(run_sourced "$C" env_get_file "$C/.env" DASHBOARD_DATA_DIR)"
MOVED_DASHBOARD_DIR="$C/data/dashboard-moved"
mkdir -p "$LIVE_DASHBOARD_DIR"
python3 -c 'import sqlite3,sys
db=sqlite3.connect(sys.argv[1]); db.execute("CREATE TABLE IF NOT EXISTS kv_store (key TEXT PRIMARY KEY, value TEXT)"); db.execute("INSERT OR REPLACE INTO kv_store VALUES (?,?)", ("payout_wallet",sys.argv[2])); db.commit()' \
    "$LIVE_DASHBOARD_DIR/mining_data.db" "$WALLET"

# The payout destination. The suffix is CORRECT on purpose: a wrong one would prove only that the
# typo check works, which was never the question. This is the case that used to APPLY.
jq --arg w "$ATTACKER_WALLET" --arg d "$MOVED_DASHBOARD_DIR" \
    '.monero.wallet_address=$w | .dashboard.data_dir=$d' "$C/config.json" >"$C/cand.json"
gate_try "$C/cand.json"
assert_eq "payout swap is refused without confirmation" "$(jq -r '.status' "$RESULTS/$UUID5.json" 2>/dev/null)" "rejected"
gate_try "$C/cand.json" APPLY "$(jq -n --arg s "${ATTACKER_WALLET: -8}" '{payout_suffixes:{monero:$s}}')"
assert_eq "confirmed payout swap applies" "$(jq -r '.status' "$RESULTS/$UUID5.json" 2>/dev/null)" "applied"
assert_eq "config.json carries the confirmed payout address" "$(jq -r '.monero.wallet_address' "$C/config.json")" "$ATTACKER_WALLET"
assert_contains ".env carries the confirmed payout address" "$(cat "$C/.env")" "MONERO_WALLET_ADDRESS=$ATTACKER_WALLET"
# An operator-pinned dashboard.data_dir is never moved for the operator (#455): the run warns and
# leaves both directories alone, so the live DB — and the payout-wallet alarm baseline in it —
# stays at the old path. Carrying it across a confirmed move is issue #2360, not this gate.
assert_eq "operator-pinned dashboard-data move leaves the baseline at the old path" \
    "$(python3 -c 'import sqlite3,sys; print(sqlite3.connect(sys.argv[1]).execute("SELECT value FROM kv_store WHERE key=\"payout_wallet\"").fetchone()[0])' "$LIVE_DASHBOARD_DIR/mining_data.db")" "$WALLET"
if [ -e "$LIVE_DASHBOARD_DIR" ]; then ok "operator-pinned dashboard-data move keeps the old path"; else bad "operator-pinned dashboard-data move keeps the old path" "removed"; fi
if [ -e "$MOVED_DASHBOARD_DIR/mining_data.db" ]; then bad "operator-pinned move does not carry the DB (#2360)" "carried anyway"; else ok "operator-pinned move does not carry the DB (#2360)"; fi

# Deanonymisation and egress: both applied before the 2026-09-13 perimeter audit, and both are asserted refused token-less
# in the battery next door — which is exactly how that battery stayed green against this.
jq '.p2pool.clearnet=true' "$C/config.json" >"$C/cand.json"
gate_try "$C/cand.json"
assert_eq "p2pool clearnet flip is refused without confirmation" "$(jq -r '.status' "$RESULTS/$UUID5.json" 2>/dev/null)" "rejected"
gate_try "$C/cand.json" APPLY "$SELF_ENVELOPE"
assert_eq "confirmed p2pool clearnet flip applies" "$(jq -r '.status' "$RESULTS/$UUID5.json" 2>/dev/null)" "applied"
jq '.network={tor_egress_firewall:false}' "$C/config.json" >"$C/cand.json"
gate_try "$C/cand.json"
assert_eq "tor-egress-firewall disable is refused without confirmation" "$(jq -r '.status' "$RESULTS/$UUID5.json" 2>/dev/null)" "rejected"
gate_try "$C/cand.json" APPLY "$SELF_ENVELOPE"
assert_eq "confirmed tor-egress-firewall disable applies" "$(jq -r '.status' "$RESULTS/$UUID5.json" 2>/dev/null)" "applied"

# A view key reveals every incoming payout amount and time, so it confirms rather than direct-commits.
MONERO_VIEW_KEY=$(printf '1%.0s' {1..64})
jq --arg k "$MONERO_VIEW_KEY" '.monero.view_key=$k' "$C/config.json" >"$C/cand.json"
gate_try "$C/cand.json"
assert_eq "monero view-key set is refused without confirmation" "$(jq -r '.status' "$RESULTS/$UUID5.json" 2>/dev/null)" "rejected"
gate_try "$C/cand.json" APPLY "$SELF_ENVELOPE"
assert_eq "confirmed monero view-key set applies" "$(jq -r '.status' "$RESULTS/$UUID5.json" 2>/dev/null)" "applied"

confirm_scalar() { # <label> <jq-filter> <read-filter> <expected>
    local label="$1" filter="$2" read_filter="$3" expected="$4"
    jq "$filter" "$C/config.json" >"$C/cand.json"
    gate_try "$C/cand.json"
    assert_eq "$label refuses without confirmation" "$(jq -r '.status' "$RESULTS/$UUID5.json")" "rejected"
    gate_try "$C/cand.json" APPLY "$SELF_ENVELOPE"
    assert_eq "$label applies with confirmation" "$(jq -r '.status' "$RESULTS/$UUID5.json")" "applied"
    assert_eq "$label lands in config.json" "$(jq -r "$read_filter" "$C/config.json")" "$expected"
}

echo "== black-box: each moved perimeter class confirms and applies (#1959) =="
confirm_scalar "stratum password" '.p2pool.stratum_password="rotated-secret"' '.p2pool.stratum_password' "rotated-secret"
confirm_scalar "stratum bind" '.p2pool.stratum_bind="127.0.0.1"' '.p2pool.stratum_bind' "127.0.0.1"
confirm_scalar "XvB endpoint" '.xvb.url="eu.xmrvsbeast.com:4247"' '.xvb.url' "eu.xmrvsbeast.com:4247"
confirm_scalar "XvB Tor route" '.xvb.tor=false' '.xvb.tor' "false"
confirm_scalar "dashboard host" '.dashboard.host="confirmed.lan"' '.dashboard.host' "confirmed.lan"
confirm_scalar "dashboard username" '.dashboard.auth.username="operator"' '.dashboard.auth.username' "operator"
confirm_scalar "dashboard onion" '.dashboard.onion.enabled=true' '.dashboard.onion.enabled' "true"
confirm_scalar "dashboard onion and client-auth disable" '.dashboard.onion={enabled:false,client_auth:false}' '.dashboard.onion.client_auth' "false"
confirm_scalar "Monero node credentials" '.monero.node_username="rpc-user" | .monero.node_password="rpc-secret"' '.monero.node_username + ":" + .monero.node_password' "rpc-user:rpc-secret"
confirm_scalar "Monero RPC and ZMQ binds" '.monero.rpc_lan_access=true | .monero.zmq_lan_access=true' '(.monero.rpc_lan_access|tostring) + ":" + (.monero.zmq_lan_access|tostring)' "true:true"
confirm_scalar "Tari gRPC bind" '.tari.grpc_lan_access=true' '.tari.grpc_lan_access' "true"
confirm_scalar "healthchecks endpoint" '.healthchecks.ping_url="https://example.com/ping"' '.healthchecks.ping_url' "https://example.com/ping"
confirm_scalar "Telegram destination" '.telegram.bot_token="654321:confirmed-ABC_def" | .telegram.chat_id="2222"' '.telegram.bot_token + ":" + .telegram.chat_id' "654321:confirmed-ABC_def:2222"
confirm_scalar "ntfy destination" '.notifications.ntfy={url:"https://ntfy.example/topic",token:"ntfy-secret"}' '.notifications.ntfy.url + ":" + .notifications.ntfy.token' "https://ntfy.example/topic:ntfy-secret"
unset -f confirm_scalar

TARI_VIEW_KEY=$(printf '2%.0s' {1..64})
TARI_SPEND_KEY=$(printf '3%.0s' {1..64})
jq --arg v "$TARI_VIEW_KEY" --arg s "$TARI_SPEND_KEY" '.tari.view_key=$v | .tari.spend_public_key=$s' "$C/config.json" >"$C/cand.json"
gate_try "$C/cand.json"
assert_eq "Tari payout-confirmation keys refuse without confirmation" "$(jq -r '.status' "$RESULTS/$UUID5.json")" "rejected"
gate_try "$C/cand.json" APPLY "$SELF_ENVELOPE"
assert_eq "Tari payout-confirmation keys apply with confirmation" "$(jq -r '.status' "$RESULTS/$UUID5.json")" "applied"
assert_eq "Tari private view key lands in config.json" "$(jq -r '.tari.view_key' "$C/config.json")" "$TARI_VIEW_KEY"

# POSITIVE CONTROL. The tier was narrowed, not emptied: without this row every assertion above
# would also pass if the envelope path had been broken outright rather than scoped, and a gate
# that refuses everything is not the property the 2026-09-13 perimeter audit claims.
jq '.telegram={enabled:true,bot_token:"123456:legit-ABC_def",chat_id:"1111"}' "$C/config.json" >"$C/cand.json" && mv "$C/cand.json" "$C/config.json"
(cd "$C" && DOCKER_LOG="$CTRL_LOG" PATH="$C/bin:$PATH" ./pithead apply -y >/dev/null 2>&1)
jq '.telegram.enabled=false' "$C/config.json" >"$C/cand.json"
gate_try "$C/cand.json" APPLY "$SELF_ENVELOPE"
assert_eq "an APPROVAL-tier key still commits with the envelope" "$(jq -r '.status' "$RESULTS/$UUID5.json" 2>/dev/null)" "applied"
assert_eq "the approval-tier change landed" "$(jq -r '.telegram.enabled' "$C/config.json")" "false"
# A hostname changes the appliance's certificate and mDNS identity. It is approval-tier rather
# than host-only: a bare hostname is validated before render and this route is the appliance's
# only day-two path. The envelope control below reddens if HOST_IP falls back to default-deny.
jq '.dashboard.host="next-box"' "$C/config.json" >"$C/cand.json"
gate_try "$C/cand.json" APPLY "$SELF_ENVELOPE"
assert_eq "an approval-gated dashboard hostname commits with the envelope" "$(jq -r '.status' "$RESULTS/$UUID5.json" 2>/dev/null)" "applied"
assert_eq "the approval-gated dashboard hostname landed" "$(jq -r '.dashboard.host' "$C/config.json")" "next-box"
jq '.dashboard.host="bare-box"' "$C/config.json" >"$C/cand.json"
gate_try "$C/cand.json" APPLY ""
assert_eq "an approval-gated dashboard hostname is refused without the envelope" "$(jq -r '.status' "$RESULTS/$UUID5.json" 2>/dev/null)" "rejected"
assert_eq "the refused bare hostname did not land" "$(jq -r '.dashboard.host' "$C/config.json")" "next-box"
# ...and the alarm toggles on that same channel stay physical-presence-only, envelope or not.
jq '.telegram.events={wallet_changed:false}' "$C/config.json" >"$C/cand.json"
gate_try "$C/cand.json" APPLY "$SELF_ENVELOPE"
assert_eq "the wallet-changed alarm cannot be silenced with an envelope" "$(jq -r '.status' "$RESULTS/$UUID5.json" 2>/dev/null)" "rejected"
assert_contains "the alarm refusal names the physical-presence route" "$(jq -r '.error' "$RESULTS/$UUID5.json" 2>/dev/null)" "configuration stick"

# Switching the control channel off is how an attacker locks the operator out of the remedy. It
# runs last because an applied disable correctly stops this test's own remaining spool requests.
jq '.dashboard.control.enabled=false' "$C/config.json" >"$C/cand.json"
gate_try "$C/cand.json"
assert_eq "control-channel disable is refused without confirmation" "$(jq -r '.status' "$RESULTS/$UUID5.json" 2>/dev/null)" "rejected"
gate_try "$C/cand.json" APPLY "$SELF_ENVELOPE"
assert_eq "confirmed control-channel disable applies" "$(jq -r '.status' "$RESULTS/$UUID5.json" 2>/dev/null)" "applied"
