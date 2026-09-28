# shellcheck shell=bash
: "${STACK_SUITE:?is unset: this file is a tests/stack/run.sh fragment, not a script — run tests/stack/run.sh}"
# Security regressions for confirmed worker descriptors and masked remote capabilities (#1959).
# Position-locked after test-control-add-only-ssrf.sh: gate_try() and the shared control sandbox are
# provided there. The next domain rebuilds its own baseline, so this fragment may commit freely.
: "${C:?}" "${CTRL_LOG:?}" "${SANDBOX:?}" "${WALLET:?}" "${VALID_TARI:?}" "${REQS:?}" "${RESULTS:?}"
declare -F gate_try >/dev/null || {
    printf 'gate_try is unavailable\n' >&2
    return 1
}

echo "== black-box: confirmed worker secrets and dial targets stay bound (#1959) =="
jq -n --arg w "$WALLET" '{
    monero:{mode:"local",wallet_address:$w,node_username:"u",node_password:"p"},
    tari:{wallet_address:"'"$VALID_TARI"'"}, p2pool:{pool:"mini"},
    workers:{api_port:8080,api_auth:"token",api_token:"fleet-token",list:[
      {name:"rig-1",host:"192.168.1.50",control_port:8082,token:"rig-token",api_token:"rig-read-token"}]},
    notifications:{webhooks:["https://example.com/hook"],
                   ntfy:{url:"https://ntfy.example/old",token:"ntfy-token"}},
    dashboard:{secure:true,host:"box.lan",auth:{username:"admin",password:"a control passphrase"},
               control:{enabled:true}}}' >"$C/config.json"
(cd "$C" && DOCKER_LOG="$CTRL_LOG" PATH="$C/bin:$PATH" ./pithead apply -y >/dev/null 2>&1)

# Resolve one ordinary RFC1918 address as this host's own interface. Other LAN addresses remain
# distinct rigs, so the same seam covers the negative and positive worker cases below.
cat >"$C/bin/getent" <<'EOF'
#!/usr/bin/env bash
if [ "$1" = "ahosts" ] && [ "$2" = "this-host-lan" ]; then
    printf '192.168.1.88 STREAM this-host-lan\n'
    exit 0
fi
exec /usr/bin/getent "$@"
EOF
cat >"$C/bin/ip" <<'EOF'
#!/usr/bin/env bash
# #2671's interface list sees nothing of this host's here, so the refusal below is the route check's.
case "$*" in
"-o addr show") echo "1: lo    inet 127.0.0.1/8 scope host lo" && exit 0 ;;
"-o link show type bridge" | "-4 route show default" | "-6 route show default") exit 0 ;;
esac
[ "$1" = "route" ] && [ "$2" = "get" ] || exit 2
if [ "$3" = "192.168.1.88" ]; then
    printf 'local %s dev lo src %s\n' "$3" "$3"
else
    printf '%s via 192.168.1.1 dev eth0\n' "$3"
fi
EOF
chmod +x "$C/bin/getent" "$C/bin/ip"
jq '.workers.list += [{name:"local-alias",host:"this-host-lan",control_port:8082,token:"attacker"}]' \
    "$C/config.json" >"$C/cand.json"
gate_try "$C/cand.json"
assert_contains "ordinary LAN address on this host is refused" \
    "$(jq -r '.error // ""' "$RESULTS/$UUID5.json")" "resolves inside this host"

GUARD_UUID="19191919-1959-4959-8959-191919191959"
# A masked fleet bearer cannot acquire a new recipient through a tokenless worker descriptor.
jq -n --slurpfile live "$C/config.json" --arg id "$GUARD_UUID" \
    '{id:$id,action:"preview",actor:"admin",config:($live[0]
      | .workers.api_token={"__secret__":true}
      | .workers.list += [{name:"global-rig",host:"192.168.1.52"}])}' >"$REQS/$GUARD_UUID.json"
run_pending >/dev/null
assert_eq "tokenless worker cannot inherit a masked fleet bearer" \
    "$(jq -r '.status' "$RESULTS/$GUARD_UUID.json")" "rejected"
assert_contains "fleet bearer refusal asks for the shared token" \
    "$(jq -r '.error' "$RESULTS/$GUARD_UUID.json")" "workers.api_token"
jq -n --slurpfile live "$C/config.json" --arg id "$GUARD_UUID" \
    '{id:$id,action:"preview",actor:"admin",config:($live[0]
      | .workers.api_token="replacement-fleet-token"
      | .workers.list += [{name:"global-rig",host:"192.168.1.52"}])}' >"$REQS/$GUARD_UUID.json"
run_pending >/dev/null
assert_eq "tokenless worker with an explicit fleet bearer is previewed" \
    "$(jq -r '.status' "$RESULTS/$GUARD_UUID.json")" "previewed"

# An ntfy bearer and Monero RPC credentials are likewise bound to their current destinations.
jq -n --slurpfile live "$C/config.json" --arg id "$GUARD_UUID" \
    '{id:$id,action:"preview",actor:"admin",config:($live[0]
      | .notifications.ntfy.url="https://ntfy.example/new"
      | .notifications.ntfy.token={"__secret__":true})}' >"$REQS/$GUARD_UUID.json"
run_pending >/dev/null
assert_eq "ntfy repoint cannot reuse a masked bearer" \
    "$(jq -r '.status' "$RESULTS/$GUARD_UUID.json")" "rejected"
assert_contains "ntfy repoint asks for the replacement token" \
    "$(jq -r '.error' "$RESULTS/$GUARD_UUID.json")" "new URL"

jq -n --slurpfile live "$C/config.json" --arg id "$GUARD_UUID" \
    '{id:$id,action:"preview",actor:"admin",config:($live[0]
      | .monero.mode="remote"
      | .monero.remote={host:"node.example",rpc_port:18081,zmq_port:18083}
      | .monero.node_username={"__secret__":true}
      | .monero.node_password={"__secret__":true})}' >"$REQS/$GUARD_UUID.json"
run_pending >/dev/null
assert_eq "Monero repoint cannot reuse masked RPC credentials" \
    "$(jq -r '.status' "$RESULTS/$GUARD_UUID.json")" "rejected"
assert_contains "Monero repoint asks for replacement credentials" \
    "$(jq -r '.error' "$RESULTS/$GUARD_UUID.json")" "new endpoint"

# A per-worker bearer whose port inherits workers.api_port is bound to that effective port, not
# merely to the absent raw .port leaf.
jq -n --slurpfile live "$C/config.json" --arg id "$GUARD_UUID" \
    '{id:$id,action:"preview",actor:"admin",config:($live[0]
      | .workers.api_port=8081
      | .workers.api_token="replacement-fleet-token"
      | .workers.list[0].token={"__secret__":true})}' >"$REQS/$GUARD_UUID.json"
run_pending >/dev/null
assert_eq "inherited worker port cannot repoint a masked per-worker bearer" \
    "$(jq -r '.status' "$RESULTS/$GUARD_UUID.json")" "rejected"
assert_contains "inherited-port refusal names the masked worker token" \
    "$(jq -r '.error' "$RESULTS/$GUARD_UUID.json")" "masked worker token"

jq -n --slurpfile live "$C/config.json" --arg id "$GUARD_UUID" \
    '{id:$id,action:"preview",actor:"admin",config:($live[0]
      | .workers.api_port=8081
      | .workers.list[0].api_token={"__secret__":true})}' >"$REQS/$GUARD_UUID.json"
run_pending >/dev/null
assert_eq "inherited worker port cannot repoint a masked read-only probe bearer" \
    "$(jq -r '.status' "$RESULTS/$GUARD_UUID.json")" "rejected"
assert_contains "inherited-port refusal names the masked worker credential" \
    "$(jq -r '.error' "$RESULTS/$GUARD_UUID.json")" "masked worker token"

jq -n --slurpfile live "$C/config.json" --arg id "$GUARD_UUID" \
    '{id:$id,action:"preview",actor:"admin",config:($live[0]
      | .workers.api_token={"__secret__":true}
      | .workers.list[0].host="192.168.1.51"
      | .workers.list[0].token={"__secret__":true})}' >"$REQS/$GUARD_UUID.json"
run_pending >/dev/null
assert_eq "worker repoint cannot reuse a masked bearer" \
    "$(jq -r '.status' "$RESULTS/$GUARD_UUID.json")" "rejected"
assert_contains "masked-token repoint names the host route, not a token retry" \
    "$(jq -r '.error' "$RESULTS/$GUARD_UUID.json")" "on the host"

jq -n --slurpfile live "$C/config.json" --arg id "$GUARD_UUID" \
    '{id:$id,action:"preview",actor:"admin",config:($live[0]
      | .workers.api_token={"__secret__":true}
      | .workers.list[0].host="192.168.1.51"
      | .workers.list[0].token="replacement-token")}' >"$REQS/$GUARD_UUID.json"
run_pending >/dev/null
# Even with an explicit replacement bearer, a repoint edits an adopted rig: refused (#2641/#912).
assert_eq "worker repoint with an explicit bearer is refused at preview" \
    "$(jq -r '.status' "$RESULTS/$GUARD_UUID.json")" "rejected"
assert_contains "worker repoint refusal names the adopted-rig boundary" \
    "$(jq -r '.error' "$RESULTS/$GUARD_UUID.json")" "already controls"
assert_not_contains "worker repoint refusal never echoes the bearer" \
    "$(cat "$RESULTS/$GUARD_UUID.json")" "replacement-token"
jq -n --arg id "$GUARD_UUID" \
    '{id:$id,action:"commit",actor:"admin",confirm:"APPLY",approval:{payout_suffixes:{}}}' >"$REQS/$GUARD_UUID.json"
run_pending >/dev/null
assert_eq "APPLY does not commit a worker repoint" "$(jq -r '.status' "$RESULTS/$GUARD_UUID.json")" "rejected"
assert_eq "worker repoint leaves the host and bearer as they were" \
    "$(jq -r '.workers.list[0] | .host + "|" + .token' "$C/config.json")" "192.168.1.50|rig-token"

# Same-host field edits of an adopted rig are edits too, even riding with a valid adopt: an explicit
# new token or control port is refused with APPLY, so a host-only prefix check could not pass them.
for EDIT in '.workers.list[0].token="edited-token"' '.workers.list[0].control_port=9082'; do
    jq -n --slurpfile live "$C/config.json" --arg id "$GUARD_UUID" \
        '{id:$id,action:"preview",actor:"admin",config:($live[0] | '"$EDIT"'
          | .workers.list += [{name:"rig-9",host:"192.168.1.60",control_port:8082,token:"t9"}])}' >"$REQS/$GUARD_UUID.json"
    run_pending >/dev/null
    jq -n --arg id "$GUARD_UUID" '{id:$id,action:"commit",actor:"admin",confirm:"APPLY"}' >"$REQS/$GUARD_UUID.json"
    run_pending >/dev/null
    assert_contains "a same-host edit of an adopted rig is refused with APPLY (${EDIT%%=*})" \
        "$(jq -r '"\(.status): \(.error)"' "$RESULTS/$GUARD_UUID.json")" "rejected: this change edits or removes a rig the dashboard already controls"
done
assert_eq "same-host edits leave the adopted rig as it was and adopt nothing" \
    "$(jq -r '"\(.workers.list[0].token)|\(.workers.list[0].control_port)|\(.workers.list | length)"' "$C/config.json")" "rig-token|8082|1"

# Webhook sentinels restore by position, and each carries the live slot it was masked at (#2373).
jq '.notifications.webhooks=["https://example.com/hook","https://example.com/two"]' "$C/config.json" >"$C/config.json.tmp" &&
    mv "$C/config.json.tmp" "$C/config.json"
(cd "$C" && DOCKER_LOG="$CTRL_LOG" PATH="$C/bin:$PATH" ./pithead apply -y >/dev/null 2>&1)
S0='{"__secret__":true,"slot":0}' S1='{"__secret__":true,"slot":1}'
webhook_preview() { # <hooks-json> -> "<status>: <error>"
    jq -n --slurpfile live "$C/config.json" --arg id "$GUARD_UUID" --argjson hooks "$1" \
        '{id:$id,action:"preview",actor:"admin",config:($live[0] | .notifications.webhooks=$hooks)}' >"$REQS/$GUARD_UUID.json"
    run_pending >/dev/null
    jq -r '"\(.status): \(.error)"' "$RESULTS/$GUARD_UUID.json"
}
jq -n --slurpfile live "$C/config.json" --arg id "$GUARD_UUID" --argjson s0 "$S0" --argjson s1 "$S1" \
    '{id:$id,action:"preview",actor:"admin",config:($live[0]
      | .notifications.webhooks=[$s0,$s1]
      | .p2pool.pool="nano")}' >"$REQS/$GUARD_UUID.json"
run_pending >/dev/null
jq -n --arg id "$GUARD_UUID" '{id:$id,action:"commit",actor:"admin"}' >"$REQS/$GUARD_UUID.json"
run_pending >/dev/null
assert_eq "masked webhooks survive an unrelated commit in their own slots" \
    "$(jq -c '.notifications.webhooks' "$C/config.json")" '["https://example.com/hook","https://example.com/two"]'
assert_contains "a same-length edit that keeps each masked slot still previews" \
    "$(webhook_preview "[$S0,\"https://example.com/new\"]")" "previewed"
# Added, removed or moved entries would restore another live URL into a masked slot. A sentinel
# with no slot cannot prove where it came from.
for HOOKS in "[\"https://example.com/new\",$S0,$S1]" "[$S0]" "[$S1,$S0]" '[{"__secret__":true},{"__secret__":true}]'; do
    assert_contains "masked webhooks that no longer line up are refused ($HOOKS)" \
        "$(webhook_preview "$HOOKS")" "rejected: notifications.webhooks were added, removed or reordered"
done
assert_eq "refused webhook edits leave the live list as it was" \
    "$(jq -c '.notifications.webhooks' "$C/config.json")" '["https://example.com/hook","https://example.com/two"]'
rm -f "$C/bin/getent" "$C/bin/ip"

# A DNS name can change after the safety check. Resolve safely for both host checks, then return
# loopback on any later lookup; curl must receive the already-validated numeric address.
REBIND_DIR="$SANDBOX/control-dial-rebind"
mkdir -p "$REBIND_DIR/staged" "$REBIND_DIR/results" "$REBIND_DIR/audit" "$REBIND_DIR/bin"
printf '{"workers":{"list":[{"name":"rig","host":"rebind-rig","control_port":8082,"token":"secret"}]}}\n' >"$REBIND_DIR/config.json"
cat >"$REBIND_DIR/bin/getent" <<'EOF'
#!/usr/bin/env bash
count=0
[ ! -f "${REBIND_COUNTER:?}" ] || read -r count <"$REBIND_COUNTER"
count=$((count + 1))
printf '%s\n' "$count" >"$REBIND_COUNTER"
if [ "$count" -le 2 ]; then
    printf '192.168.1.77 STREAM rebind-rig\n'
else
    printf '127.0.0.1 STREAM rebind-rig\n'
fi
EOF
cat >"$REBIND_DIR/bin/ip" <<'EOF'
#!/usr/bin/env bash
[ ! -e "${IP_FAILS:-/nonexistent}" ] || exit 1
case "$*" in
"-o addr show") echo "1: lo    inet 127.0.0.1/8 scope host lo" ;;
"-o link show type bridge" | "-4 route show default" | "-6 route show default") ;;
"route get "*) printf '%s via 192.168.1.1 dev eth0\n' "$3" ;;
*) exit 1 ;;
esac
EOF
cat >"$REBIND_DIR/bin/curl" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$@" >"${DIAL_LOG:?}"
exit 7
EOF
chmod +x "$REBIND_DIR/bin/getent" "$REBIND_DIR/bin/ip" "$REBIND_DIR/bin/curl"
REBIND_UUID="29292929-1959-4959-8959-292929291959"
printf '{"id":"%s","action":"worker-apply","actor":"admin","worker":"rig","changes":{"DONATION":2}}\n' \
    "$REBIND_UUID" >"$REBIND_DIR/req.json"
PATH="$REBIND_DIR/bin:$PATH" REBIND_COUNTER="$REBIND_DIR/.resolved-count" \
    DIAL_LOG="$REBIND_DIR/.curl-args" \
    CONTROL_WA_BUDGET=1 PITHEAD_CONFIG_FILE="$REBIND_DIR/config.json" \
    run_sourced_e "$SANDBOX" control_process_request "$REBIND_DIR/req.json" "$REBIND_DIR" >/dev/null 2>&1
assert_contains "worker dial reports curl failure after its target passes validation" \
    "$(jq -r '.status + "|" + (.error // "")' "$REBIND_DIR/results/$REBIND_UUID.json")" \
    "failed|could not reach"
assert_eq "worker target is resolved only for validation and pinning" \
    "$(cat "$REBIND_DIR/.resolved-count")" "2"
assert_contains "worker curl uses a pinned address" "$(cat "$REBIND_DIR/.curl-args")" "--resolve"
assert_contains "worker curl pins the validated address" "$(cat "$REBIND_DIR/.curl-args")" \
    "rebind-rig:8082:192.168.1.77"

# Interface discovery that fails at dial time refuses the dial instead of sending the bearer
# (#2671's fail-closed floor, applied on the pinning path).
rm -f "$REBIND_DIR/.resolved-count" "$REBIND_DIR/.curl-args" "$REBIND_DIR/results/$REBIND_UUID.json"
: >"$REBIND_DIR/.ip-fails"
PATH="$REBIND_DIR/bin:$PATH" REBIND_COUNTER="$REBIND_DIR/.resolved-count" IP_FAILS="$REBIND_DIR/.ip-fails" \
    DIAL_LOG="$REBIND_DIR/.curl-args" \
    CONTROL_WA_BUDGET=1 PITHEAD_CONFIG_FILE="$REBIND_DIR/config.json" \
    run_sourced_e "$SANDBOX" control_process_request "$REBIND_DIR/req.json" "$REBIND_DIR" >/dev/null 2>&1
assert_eq "an unreadable interface list refuses the worker dial" \
    "$(jq -r '.status' "$REBIND_DIR/results/$REBIND_UUID.json" 2>/dev/null)" "rejected"
[ ! -e "$REBIND_DIR/.curl-args" ] && ok "no curl runs while interface discovery fails" ||
    bad "no curl runs while interface discovery fails" "curl ran: $(cat "$REBIND_DIR/.curl-args")"

# A dual-stack rig on a host with no IPv6 route: the unroutable AAAA is not "local", and the pin
# prefers the IPv4 answer, so a rig that worked before the dial-time re-check still dials.
rm -f "$REBIND_DIR/.curl-args" "$REBIND_DIR/results/$REBIND_UUID.json" "$REBIND_DIR/.ip-fails"
cat >"$REBIND_DIR/bin/getent" <<'EOF'
#!/usr/bin/env bash
printf '2001:db8:9::77 STREAM rebind-rig\n203.0.113.77 STREAM rebind-rig\n'
EOF
cat >"$REBIND_DIR/bin/ip" <<'EOF'
#!/usr/bin/env bash
case "$*" in
"-o addr show") echo "1: lo    inet 127.0.0.1/8 scope host lo" ;;
"-o link show type bridge" | "-4 route show default" | "-6 route show default") ;;
"route get 2001:"*) echo "RTNETLINK answers: Network is unreachable" >&2 && exit 2 ;;
"route get "*) printf '%s via 192.168.1.1 dev eth0\n' "$3" ;;
*) exit 1 ;;
esac
EOF
PATH="$REBIND_DIR/bin:$PATH" DIAL_LOG="$REBIND_DIR/.curl-args" \
    CONTROL_WA_BUDGET=1 PITHEAD_CONFIG_FILE="$REBIND_DIR/config.json" \
    run_sourced_e "$SANDBOX" control_process_request "$REBIND_DIR/req.json" "$REBIND_DIR" >/dev/null 2>&1
assert_contains "a dual-stack rig with an unroutable AAAA still reaches the dial" \
    "$(jq -r '.status + "|" + (.error // "")' "$REBIND_DIR/results/$REBIND_UUID.json")" "failed|could not reach"
# The resolver sorts its answers, and 2001:... sorts before 203...: the IPv6 address comes first.
assert_contains "the dual-stack pin prefers the IPv4 answer" "$(cat "$REBIND_DIR/.curl-args" 2>/dev/null)" \
    "rebind-rig:8082:203.0.113.77"
