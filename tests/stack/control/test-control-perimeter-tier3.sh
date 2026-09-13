# shellcheck shell=bash
: "${STACK_SUITE:?is unset: this file is a tests/stack/run.sh fragment, not a script — run tests/stack/run.sh}"
# The three-tier commit perimeter (2026-09-13 perimeter audit): what a SELF-WRITTEN approval envelope cannot reach.
#
# WHY THIS FILE EXISTS, AND WHY IT IS NOT IN test-control-add-only-ssrf.sh. That file's whole
# "TRUE default-deny" battery sent TOKEN-LESS commits, so each refusal proved only that the gate
# stopped at a MISSING envelope — not that the perimeter held. It did not: a commit carrying a
# self-written envelope applied a Monero payout-wallet swap, a p2pool clearnet flip, a
# tor_egress_firewall disable and a control-channel disable, measured on develop @ acb3d61f. The
# envelope is not a second identity (#2076 removed that; 42-control-approval-helpers.sh says so in
# its own header): the dashboard container writes the request spool, so it picks its own `actor`,
# types its own "APPLY", and computes the payout suffix from the very address it is proposing —
# control_validate_approval then compares one attacker-supplied value against another.
#
# Every case below therefore sends the envelope. The file is separate because
# test-control-add-only-ssrf.sh sits at its file-budget ceiling and this battery does not fit in
# it — the same reason that file was itself split out (see its header, #1105 Phase 0).
#
# POSITION-LOCKED: run.sh sources this immediately after test-control-add-only-ssrf.sh, and it
# reads gate_try() and $UUID5 from there — both deliberately outlive that source, as its header
# says. It re-derives its own spool paths and seeds its own baseline from the host CLI, so it
# borrows no ambient fixture beyond those two names.
#
# MUTATION PROOF: widening control_committable_re (42-) to re-admit any perimeter key, or turning
# the `bad` refusal in control_approval_gate back into approval_required=1, reddens every
# "is refused with a self-written envelope" row here while leaving the token-less battery next
# door green — which is precisely the blind spot this file was written to close.

REQS="$C/data/control/requests"
RESULTS="$C/data/control/results"

# The envelope a compromised container writes for itself: no operator typed any of it.
SELF_ENVELOPE='{"payout_suffixes":{}}'
# A second checksum-valid mainnet primary (the Monero project's legacy donation address).
ATTACKER_WALLET="44AFFq5kSiGBoZ4NMDwYtN18obc8AemS33DBLWs3H7otXft3XjrpDtQGv7SqSsaBYBb98uNbr2VBBEt7f2wfn3RVGQBEP3A"

echo "== black-box: a self-written approval envelope does not cross the perimeter (2026-09-13 perimeter audit) =="
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
gate_try "$C/cand.json" APPLY "$(jq -n --arg s "${ATTACKER_WALLET: -8}" '{payout_suffixes:{monero:$s}}')"
assert_eq "payout swap is refused with a CORRECT self-written suffix" "$(jq -r '.status' "$RESULTS/$UUID5.json" 2>/dev/null)" "rejected"
assert_contains "the payout refusal names the key, not the suffix" "$(jq -r '.error' "$RESULTS/$UUID5.json" 2>/dev/null)" "MONERO_WALLET_ADDRESS"
assert_eq "config.json keeps the operator's payout address" "$(jq -r '.monero.wallet_address' "$C/config.json")" "$WALLET"
assert_contains ".env keeps the operator's payout address" "$(cat "$C/.env")" "MONERO_WALLET_ADDRESS=$WALLET"

# Switching the control channel off is how an attacker locks the operator out of the remedy.
jq '.dashboard.control.enabled=false' "$C/config.json" >"$C/cand.json"
gate_try "$C/cand.json" APPLY "$SELF_ENVELOPE"
assert_eq "control-channel disable is refused with a self-written envelope" "$(jq -r '.status' "$RESULTS/$UUID5.json" 2>/dev/null)" "rejected"
assert_eq "config.json keeps the control channel enabled" "$(jq -r '.dashboard.control.enabled' "$C/config.json")" "true"

# Deanonymisation and egress: both applied before the 2026-09-13 perimeter audit, and both are asserted refused token-less
# in the battery next door — which is exactly how that battery stayed green against this.
jq '.p2pool.clearnet=true' "$C/config.json" >"$C/cand.json"
gate_try "$C/cand.json" APPLY "$SELF_ENVELOPE"
assert_eq "p2pool clearnet flip is refused with a self-written envelope" "$(jq -r '.status' "$RESULTS/$UUID5.json" 2>/dev/null)" "rejected"
assert_eq "config.json keeps p2pool on Tor" "$(jq -r '.p2pool.clearnet // false' "$C/config.json")" "false"
jq '.network={tor_egress_firewall:false}' "$C/config.json" >"$C/cand.json"
gate_try "$C/cand.json" APPLY "$SELF_ENVELOPE"
assert_eq "tor-egress-firewall disable is refused with a self-written envelope" "$(jq -r '.status' "$RESULTS/$UUID5.json" 2>/dev/null)" "rejected"
assert_eq "config.json keeps the tor egress firewall unset (defaults on)" "$(jq -r '.network.tor_egress_firewall // "unset"' "$C/config.json")" "unset"

# A view key reveals every incoming payout amount and time — a secret, never a tier.
jq '.monero.view_key="deadbeef"' "$C/config.json" >"$C/cand.json"
gate_try "$C/cand.json" APPLY "$SELF_ENVELOPE"
assert_eq "monero view-key set is refused with a self-written envelope" "$(jq -r '.status' "$RESULTS/$UUID5.json" 2>/dev/null)" "rejected"
assert_eq "config.json gains no view key" "$(jq -r '.monero.view_key // "unset"' "$C/config.json")" "unset"

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
