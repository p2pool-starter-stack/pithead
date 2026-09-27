# shellcheck shell=bash
# #2367: no config field is refused from the panel. The dashboard password and the two Telegram
# tamper alarms confirm instead, and the HOST preview (not only the form) must name what the
# change costs before the operator confirms. A token-less commit is still refused; APPLY plus the
# envelope commits. Sourced by test-control-add-only-ssrf.sh (gate_try, $UUID5).
preview_only() { # <candidate-json-file>
    jq --arg id "$UUID5" '{id:$id,action:"preview",actor:"admin",config:.}' "$1" >"$REQS/$UUID5.json"
    run_pending >/dev/null
}
previewed_with() { # <needle...>: previewed, envelope-gated, and one change message carries every needle
    jq -r --args '.status == "previewed" and .approval_required
        and ([.changes[].msg] | any(. as $m | all($ARGS.positional[]; . as $n | $m | contains($n))))' \
        "$@" <"$RESULTS/$UUID5.json" 2>/dev/null
}
jq '.dashboard.auth.password="a replacement control passphrase"' "$C/config.json" >"$C/cand.json"
preview_only "$C/cand.json"
assert_eq "password preview is envelope-gated and names the lockout and console-login costs" \
    "$(previewed_with "locks this session out" "console root login")" "true"
jq '.telegram.events={wallet_changed:false}' "$C/config.json" >"$C/cand.json"
preview_only "$C/cand.json"
assert_eq "wallet-changed alarm off previews envelope-gated, naming the unnoticed swap" \
    "$(previewed_with "wallet swap could go unnoticed")" "true"
printf '{"id":"%s","action":"commit","actor":"admin"}\n' "$UUID5" >"$REQS/$UUID5.json"
run_pending >/dev/null
assert_contains "a token-less alarm-off commit is refused for want of typed APPLY" "$(jq -r '.error' "$RESULTS/$UUID5.json" 2>/dev/null)" "type APPLY"
assert_eq "config.json keeps the wallet-changed alarm on" "$(jq -r '.telegram.events.wallet_changed // true' "$C/config.json")" "true"
jq '.telegram.events.clearnet_exposed=false' "$C/config.json" >"$C/cand.json"
preview_only "$C/cand.json"
assert_eq "clearnet-exposure alarm off previews envelope-gated, naming the IP-exposure cost" \
    "$(previewed_with "exposing this machine's IP")" "true"
# APPLY plus the envelope commits it, and the value lands; then the same route turns it back on so
# the rows after this fragment keep their baseline.
gate_try "$C/cand.json" APPLY '{"payout_suffixes":{}}'
assert_eq "clearnet-exposure alarm off commits with typed APPLY and the envelope" "$(jq -r '.status' "$RESULTS/$UUID5.json" 2>/dev/null)" "applied"
assert_eq "config.json carries the clearnet-exposure alarm off" "$(jq -r '.telegram.events.clearnet_exposed' "$C/config.json")" "false"
jq '.telegram.events.clearnet_exposed=true' "$C/config.json" >"$C/cand.json"
gate_try "$C/cand.json" APPLY '{"payout_suffixes":{}}'
assert_eq "clearnet-exposure alarm back on through the same route" "$(jq -r '.telegram.events.clearnet_exposed' "$C/config.json")" "true"
# Notification destinations (#2367): a wrong value stops delivery or reroutes it, so the preview
# names that cost; their commit and refusal rows live in test-control-perimeter-tier3.sh.
jq '.telegram.bot_token="654321:other-ABC_def"' "$C/config.json" >"$C/cand.json"
preview_only "$C/cand.json"
assert_eq "bot-token preview is envelope-gated and names the silenced and rerouted alerts" \
    "$(previewed_with "a wrong token stops every Telegram alert" "another bot's token sends them")" "true"
jq '.telegram.chat_id="2222"' "$C/config.json" >"$C/cand.json"
preview_only "$C/cand.json"
assert_eq "chat-id preview is envelope-gated and names delivery to another chat" \
    "$(previewed_with "a wrong id stops delivery" "to another chat")" "true"
jq '.healthchecks.ping_url="https://hc.example/ping"' "$C/config.json" >"$C/cand.json"
preview_only "$C/cand.json"
assert_eq "ping-URL preview is envelope-gated and names the unnoticed outage" \
    "$(previewed_with "someone else's check" "outage here goes unnoticed")" "true"
unset -f preview_only previewed_with
