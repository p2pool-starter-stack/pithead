# shellcheck shell=bash
# The wallet-changed tamper alarm is physical-presence-only (#2367: dashboard.auth.password left
# this boundary — see test-control-add-only-ssrf.sh's password-repoint assertions below — but the
# alarm that would blind a future wallet swap stays host-only). Preview must name that boundary
# too, not merely reject it as an otherwise generic sensitive config change.
jq '.telegram.events={wallet_changed:false}' "$C/config.json" >"$C/cand.json"
jq --arg id "$UUID5" '{id:$id,action:"preview",actor:"admin",config:.}' "$C/cand.json" >"$REQS/$UUID5.json"
run_pending >/dev/null
assert_eq "wallet-changed-silencing preview is refused, not previewed as committable" "$(jq -r '.status' "$RESULTS/$UUID5.json" 2>/dev/null)" "rejected"
assert_contains "wallet-changed-silencing preview names the physical-presence path" "$(jq -r '.error' "$RESULTS/$UUID5.json" 2>/dev/null)" "configuration stick"
printf '{"id":"%s","action":"commit","actor":"admin"}\n' "$UUID5" >"$REQS/$UUID5.json"
run_pending >/dev/null
assert_eq "wallet-changed-silencing commit is refused" "$(jq -r '.status' "$RESULTS/$UUID5.json" 2>/dev/null)" "rejected"
assert_contains "wallet-changed-silencing refusal names the physical-presence path" "$(jq -r '.error' "$RESULTS/$UUID5.json" 2>/dev/null)" "configuration stick"
assert_eq "config.json keeps the wallet-changed alarm on" "$(jq -r '.telegram.events.wallet_changed' "$C/config.json")" "true"
