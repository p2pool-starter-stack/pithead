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
preview_without() {
    jq -r --arg needle "$1" 'all(.changes[].msg; contains($needle) | not)' \
        <"$RESULTS/$UUID5.json" 2>/dev/null
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
# Enabling a login from none is DEST and names the same costs. The control channel cannot carry
# that transition (control needs a password set), so assert it on the host preview function itself.
assert_eq "password enable (unset to set) previews as DEST naming the lockout and console-login costs" \
    "$(run_sourced "$C" describe_change DASHBOARD_AUTH_HASH_B64 "" "new-hash" | jq -Rr 'split("\t") | .[0] == "DEST" and (.[1] | contains("locks this session out") and contains("console root login"))')" "true"
jq '.telegram.enabled=false' "$C/config.json" >"$C/cand.json"
preview_only "$C/cand.json"
assert_eq "Telegram-off preview is envelope-gated and names every alert silenced, tamper alarms included" \
    "$(previewed_with "every Telegram alert stops" "tamper alarms included")" "true"
# Exposure keys (owner, 2026-09-27): each names what becomes visible, to whom, and what stops being
# blocked, instead of the generic "KEY: old → new" line.
exposure_previews() { # <label> <jq-edit> <needle...>
    local label="$1" edit="$2"
    shift 2
    jq "$edit" "$C/config.json" >"$C/cand.json"
    preview_only "$C/cand.json"
    assert_eq "$label" "$(previewed_with "$@")" "true"
}
exposure_previews "egress-firewall-off preview names the direct dials it stops blocking" '.network.tor_egress_firewall=false' \
    "Tor-only egress firewall DISABLED" "show this host's IP to whatever it dials"
# The default firewall keeps other containers fenced while these chosen routes reach clearnet.
exposure_previews "XvB-off-Tor preview with the firewall on names IP exposure" '.xvb.enabled=true | .xvb.tor=false' \
    "XvB donation mining OFF Tor" "XvB sees this host's IP"
exposure_previews "P2Pool-clearnet preview with the firewall on names IP exposure" '.p2pool.clearnet=true' \
    "P2Pool sidechain peers over CLEARNET" "visible to the P2Pool network"
assert_eq "P2Pool-clearnet preview never claims a PPLNS reset (#3382)" "$(preview_without "PPLNS")" "true"
assert_eq "P2Pool-clearnet preview never claims a sidechain switch (#3382)" "$(preview_without "sidechain changing")" "true"
exposure_previews "disabled XvB-off-Tor preview names the later exposure" '.xvb.enabled=false | .xvb.tor=false' \
    "there is no donation dial now" "enabling XvB later opens a direct dial"
# Firewall off in the same candidate: the route is open and the preview names the exposure.
exposure_previews "XvB-off-Tor preview with the firewall off names XvB seeing this host's IP" '.xvb.tor=false | .network.tor_egress_firewall=false' \
    "XvB donation mining OFF Tor" "XvB sees this host's IP"
exposure_previews "P2Pool-clearnet preview with the firewall off names this host's IP visible to the P2Pool network" '.p2pool.clearnet=true | .network.tor_egress_firewall=false' \
    "P2Pool sidechain peers over CLEARNET" "visible to the P2Pool network"
exposure_previews "public-IP preview names the dashboard login reachable from the internet" '.dashboard.expose_public_ip=true' \
    "Dashboard PUBLISHED" "anyone on the internet can reach the dashboard login"
out="$(run_sourced "$C" describe_change P2POOL_FLAGS '--mini --socks5 172.28.0.25:9050 --socks5-proxy-type tor --no-dns' '--mini')"
assert_not_contains "Tor removal keeps the P2Pool sidechain (#3382)" "$out" "sidechain changing"
assert_not_contains "Tor removal keeps the PPLNS window (#3382)" "$out" "PPLNS"
out="$(run_sourced "$C" describe_change P2POOL_FLAGS '--mini --socks5 172.28.0.25:9050 --socks5-proxy-type tor --no-dns' '--mini --socks5 172.29.0.25:9050 --socks5-proxy-type tor --no-dns')"
assert_not_contains "subnet-derived proxy change keeps the P2Pool sidechain (#3382)" "$out" "sidechain changing"
assert_not_contains "subnet-derived proxy change keeps the PPLNS window (#3382)" "$out" "PPLNS"

for old_flags in '' '--mini' '--nano'; do
    for new_flags in '' '--mini' '--nano'; do
        out="$(run_sourced "$C" describe_change P2POOL_FLAGS "$old_flags" "$new_flags")"
        if [ "$old_flags" != "$new_flags" ]; then
            assert_contains "pool selector $old_flags to $new_flags resets the window (#3382)" "$out" "PPLNS window resets"
        else
            assert_not_contains "same selector $old_flags keeps the window (#3382)" "$out" "PPLNS"
        fi
    done
done
out="$(run_sourced "$C" describe_change P2POOL_FLAGS $'--mini\t--no-dns' $'--mini\n--socks5 192.0.2.25:9050')"
assert_contains "routing flags separated by whitespace keep mini selected (#3382)" "$out" "mini sidechain stays selected"
out="$(run_sourced "$C" describe_change P2POOL_FLAGS '--mini' '--mini --socks5 192.0.2.25:9050 --socks5-proxy-type tor --no-dns')"
assert_contains "adding Tor describes peer routing (#3382)" "$out" "P2Pool peer routing changed"
assert_not_contains "adding Tor keeps the PPLNS window (#3382)" "$out" "PPLNS"
out="$(run_sourced "$C" describe_change P2POOL_PORT 37888 37890)"
assert_contains "pool port change retains the PPLNS reset warning (#3382)" "$out" "PPLNS window resets"

unset -f preview_only previewed_with preview_without exposure_previews

exposure_previews "donation enabling names project routing" '.donation.enabled=true' "Project donation set to true"
exposure_previews "donation percentage change names the percentage" '.donation.percent=5' "5 percent"
exposure_previews "donation off Tor names IP exposure" '.donation.tor=false' "project endpoint sees this host's IP"
jq '.donation.enabled=true' "$C/config.json" >"$C/cand.json"
preview_only "$C/cand.json"
printf '{"id":"%s","action":"commit","actor":"admin"}\n' "$UUID5" >"$REQS/$UUID5.json"
run_pending >/dev/null
assert_contains "donation commit needs typed APPLY" "$(jq -r .error "$RESULTS/$UUID5.json")" "type APPLY"
gate_try "$C/cand.json" APPLY '{"payout_suffixes":{}}'
assert_eq "donation enabling commits with typed APPLY" "$(jq -r .status "$RESULTS/$UUID5.json")" applied
assert_eq "donation change was saved" "$(jq -r .donation.enabled "$C/config.json")" true
jq 'del(.donation)' "$C/config.json" >"$C/cand.json"
gate_try "$C/cand.json" APPLY '{"payout_suffixes":{}}'
