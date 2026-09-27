# shellcheck shell=bash
# #2367: no config field is refused from the panel. The dashboard password and the two Telegram
# tamper alarms confirm instead, and the HOST preview (not only the form) must name what the
# change costs before the operator confirms. A token-less commit is still refused.
preview_only() { # <candidate-json-file>
    jq --arg id "$UUID5" '{id:$id,action:"preview",actor:"admin",config:.}' "$1" >"$REQS/$UUID5.json"
    run_pending >/dev/null
}
jq '.dashboard.auth.password="a replacement control passphrase"' "$C/config.json" >"$C/cand.json"
preview_only "$C/cand.json"
assert_eq "password preview is envelope-gated and names the lockout and console-login costs" \
    "$(jq -r '.approval_required and ([.changes[].msg] | any(contains("locks this session out") and contains("console root login")))' "$RESULTS/$UUID5.json" 2>/dev/null)" "true"
jq '.telegram.events={wallet_changed:false}' "$C/config.json" >"$C/cand.json"
preview_only "$C/cand.json"
assert_eq "wallet-changed alarm off previews as an envelope-gated DEST row naming the unnoticed swap" \
    "$(jq -r '.approval_required and ([.changes[] | select(.flag == "DEST") | .msg] | any(contains("wallet swap could go unnoticed")))' "$RESULTS/$UUID5.json" 2>/dev/null)" "true"
printf '{"id":"%s","action":"commit","actor":"admin"}\n' "$UUID5" >"$REQS/$UUID5.json"
run_pending >/dev/null
assert_contains "a token-less alarm-off commit is refused for want of typed APPLY" "$(jq -r '.error' "$RESULTS/$UUID5.json" 2>/dev/null)" "type APPLY"
assert_eq "config.json keeps the wallet-changed alarm on" "$(jq -r '.telegram.events.wallet_changed // true' "$C/config.json")" "true"
jq '.telegram.events={clearnet_exposed:false}' "$C/config.json" >"$C/cand.json"
preview_only "$C/cand.json"
assert_contains "clearnet-exposure alarm off previews the IP-exposure cost" "$(jq -r '[.changes[].msg] | join(" ")' "$RESULTS/$UUID5.json" 2>/dev/null)" "exposing this machine's IP"
unset -f preview_only
