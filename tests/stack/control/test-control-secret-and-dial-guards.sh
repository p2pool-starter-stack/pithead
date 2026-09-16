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
      {name:"rig-1",host:"192.168.1.50",control_port:8082,token:"rig-token"}]},
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

jq -n --slurpfile live "$C/config.json" --arg id "$GUARD_UUID" \
    '{id:$id,action:"preview",actor:"admin",config:($live[0]
      | .workers.api_token={"__secret__":true}
      | .workers.list[0].host="192.168.1.51"
      | .workers.list[0].token={"__secret__":true})}' >"$REQS/$GUARD_UUID.json"
run_pending >/dev/null
assert_eq "worker repoint cannot reuse a masked bearer" \
    "$(jq -r '.status' "$RESULTS/$GUARD_UUID.json")" "rejected"
assert_contains "worker repoint asks for the replacement token" \
    "$(jq -r '.error' "$RESULTS/$GUARD_UUID.json")" "enter the token"

jq -n --slurpfile live "$C/config.json" --arg id "$GUARD_UUID" \
    '{id:$id,action:"preview",actor:"admin",config:($live[0]
      | .workers.api_token={"__secret__":true}
      | .workers.list[0].host="192.168.1.51"
      | .workers.list[0].token="replacement-token")}' >"$REQS/$GUARD_UUID.json"
run_pending >/dev/null
assert_eq "worker repoint is previewed with its full old host" \
    "$(jq -r '.preview_values[] | select(.key=="workers.list.0.host") | .old' "$RESULTS/$GUARD_UUID.json")" "192.168.1.50"
assert_eq "worker repoint is previewed with its full new host" \
    "$(jq -r '.preview_values[] | select(.key=="workers.list.0.host") | .new' "$RESULTS/$GUARD_UUID.json")" "192.168.1.51"
assert_eq "worker bearer stays absent from preview values" \
    "$(jq -r 'any(.preview_values[]?; .key=="workers.list.0.token")' "$RESULTS/$GUARD_UUID.json")" "false"
jq -n --arg id "$GUARD_UUID" \
    '{id:$id,action:"commit",actor:"admin",confirm:"APPLY",approval:{payout_suffixes:{}}}' >"$REQS/$GUARD_UUID.json"
run_pending >/dev/null
assert_eq "confirmed worker repoint applies" "$(jq -r '.status' "$RESULTS/$GUARD_UUID.json")" "applied"
assert_eq "worker repoint stores only the explicit replacement bearer" \
    "$(jq -r '.workers.list[0].token' "$C/config.json")" "replacement-token"

# Webhook URLs are positional masked capabilities. An unrelated change restores the live value.
jq -n --slurpfile live "$C/config.json" --arg id "$GUARD_UUID" \
    '{id:$id,action:"preview",actor:"admin",config:($live[0]
      | .notifications.webhooks=[{"__secret__":true}]
      | .p2pool.pool="nano")}' >"$REQS/$GUARD_UUID.json"
run_pending >/dev/null
jq -n --arg id "$GUARD_UUID" '{id:$id,action:"commit",actor:"admin"}' >"$REQS/$GUARD_UUID.json"
run_pending >/dev/null
assert_eq "masked webhook survives an unrelated commit" \
    "$(jq -r '.notifications.webhooks[0]' "$C/config.json")" "https://example.com/hook"
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
printf '#!/usr/bin/env bash\nprintf "%%s via 192.168.1.1 dev eth0\\n" "$3"\n' >"$REBIND_DIR/bin/ip"
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
