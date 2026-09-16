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

# The payout destination. The suffix is CORRECT on purpose: a wrong one would prove only that the
# typo check works, which was never the question. This is the case that used to APPLY.
jq --arg w "$ATTACKER_WALLET" '.monero.wallet_address=$w' "$C/config.json" >"$C/cand.json"
gate_try "$C/cand.json"
assert_eq "payout swap is refused without confirmation" "$(jq -r '.status' "$RESULTS/$UUID5.json" 2>/dev/null)" "rejected"
gate_try "$C/cand.json" APPLY "$(jq -n --arg s "${ATTACKER_WALLET: -8}" '{payout_suffixes:{monero:$s}}')"
assert_eq "confirmed payout swap applies" "$(jq -r '.status' "$RESULTS/$UUID5.json" 2>/dev/null)" "applied"
assert_eq "config.json carries the confirmed payout address" "$(jq -r '.monero.wallet_address' "$C/config.json")" "$ATTACKER_WALLET"
assert_contains ".env carries the confirmed payout address" "$(cat "$C/.env")" "MONERO_WALLET_ADDRESS=$ATTACKER_WALLET"

# Switching the control channel off is how an attacker locks the operator out of the remedy.
jq '.dashboard.control.enabled=false' "$C/config.json" >"$C/cand.json"
gate_try "$C/cand.json"
assert_eq "control-channel disable is refused without confirmation" "$(jq -r '.status' "$RESULTS/$UUID5.json" 2>/dev/null)" "rejected"
gate_try "$C/cand.json" APPLY "$SELF_ENVELOPE"
assert_eq "confirmed control-channel disable applies" "$(jq -r '.status' "$RESULTS/$UUID5.json" 2>/dev/null)" "applied"

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

# A view key reveals every incoming payout amount and time — a secret, never a tier.
jq '.monero.view_key="deadbeef"' "$C/config.json" >"$C/cand.json"
gate_try "$C/cand.json"
assert_eq "monero view-key set is refused without confirmation" "$(jq -r '.status' "$RESULTS/$UUID5.json" 2>/dev/null)" "rejected"
gate_try "$C/cand.json" APPLY "$SELF_ENVELOPE"
assert_eq "confirmed monero view-key set applies" "$(jq -r '.status' "$RESULTS/$UUID5.json" 2>/dev/null)" "applied"

# POSITIVE CONTROL. The tier was narrowed, not emptied: without this row every assertion above
# would also pass if the envelope path had been broken outright rather than scoped, and a gate
# that refuses everything is not the property the 2026-09-13 perimeter audit claims.
jq '.telegram={enabled:true,bot_token:"123456:legit-ABC_def",chat_id:"1111"}' "$C/config.json" >"$C/cand.json" && mv "$C/cand.json" "$C/config.json"
(cd "$C" && DOCKER_LOG="$CTRL_LOG" PATH="$C/bin:$PATH" ./pithead apply -y >/dev/null 2>&1)
jq '.telegram.enabled=false' "$C/config.json" >"$C/cand.json"
gate_try "$C/cand.json" APPLY "$SELF_ENVELOPE"
assert_eq "an APPROVAL-tier key still commits with the envelope" "$(jq -r '.status' "$RESULTS/$UUID5.json" 2>/dev/null)" "applied"
assert_eq "the approval-tier change landed" "$(jq -r '.telegram.enabled' "$C/config.json")" "false"
# ...and the alarm toggles on that same channel stay physical-presence-only, envelope or not.
jq '.telegram.events={wallet_changed:false}' "$C/config.json" >"$C/cand.json"
gate_try "$C/cand.json" APPLY "$SELF_ENVELOPE"
assert_eq "the wallet-changed alarm cannot be silenced with an envelope" "$(jq -r '.status' "$RESULTS/$UUID5.json" 2>/dev/null)" "rejected"
assert_contains "the alarm refusal names the physical-presence route" "$(jq -r '.error' "$RESULTS/$UUID5.json" 2>/dev/null)" "configuration stick"
