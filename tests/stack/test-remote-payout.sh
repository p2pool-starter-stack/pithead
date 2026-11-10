# shellcheck shell=bash disable=SC2034
: "${STACK_SUITE:?source via tests/stack/run.sh}"
# shellcheck source=tests/integration/fixtures/payout-pairs.sh
source "$ROOT/tests/integration/fixtures/payout-pairs.sh"

echo "== remote-node payout confirmation: validation, routing and render (#2866) =="

for host in 10.1.2.3 127.0.0.1 172.16.0.9 172.31.255.1 192.168.1.5 100.64.0.1 100.127.1.1 169.254.1.1 0.0.0.0 localhost nas.local box fd00::1 fe80::1 ::1 :: ::ffff:192.168.1.5 0:0:0:0:0:0:0:1 node.lan. localhost.; do
    run_sourced "$SANDBOX" payout_host_off_tor "$host"
    assert_rc "Tor cannot reach a private, local or unqualified node" "$?" 0
done
for host in 8.8.8.8 172.15.0.1 172.32.0.1 100.63.0.1 100.128.0.1 node.example.com fcdn.example.com 2001:db8::1; do
    run_sourced "$SANDBOX" payout_host_off_tor "$host"
    assert_rc "Tor can reach a public node" "$?" 1
done

build_val_sandbox
RP_DIR="$SANDBOX/remote-payout"
rp_config() {
    jq -n --arg profile "$1" --arg mode "$2" --arg host "$3" --arg key "${4-$PAYOUT_VIEW1}" --arg m "$PAYOUT_MONERO1" --arg t "$PAYOUT_TARI1" \
        '{profile:$profile,
          monero:({mode:$mode,wallet_address:$m,node_username:"u",node_password:"p",view_key:$key}
                  + (if $mode == "remote" then {remote:{host:$host,rpc_port:28081}} else {} end)),
          tari:{wallet_address:$t,mode:"off"},p2pool:{pool:"main"},dashboard:{secure:true,host:"box.lan"}}' >"$V/config.json"
}
rp_apply() { (cd "$V" && PATH="$V/bin:$PATH" ./pithead apply -y 2>&1); }
rp_env() { run_sourced "$V" env_get_file "$V/.env" "$1"; }

seed_env
rp_config balance remote 192.168.1.5
out="$(rp_apply)"
assert_rc "remote node with a view key applies under Balance" "$?" 0
assert_eq "remote payout confirmation renders enabled" "$(rp_env PAYOUT_CONFIRM_ENABLED)" true
assert_eq "remote payout scan renders the remote flag" "$(rp_env PAYOUT_NODE_REMOTE)" true
assert_eq "remote payout scan uses no proxy under Balance" "$(rp_env PAYOUT_NODE_PROXY)" ""
assert_eq "remote payout scan points at the configured node" "$(rp_env MONERO_NODE_HOST):$(rp_env MONERO_RPC_PORT)" "192.168.1.5:28081"
assert_eq "remote payout adds the wallet profile without a local node" "$(rp_env COMPOSE_PROFILES)" "payout_confirm"
assert_not_contains "remote payout never prints the view key" "$out" "$PAYOUT_VIEW1"

seed_env
rp_config performance remote node.example.com
out="$(rp_apply)"
assert_rc "remote node with a view key applies under Performance" "$?" 0
assert_eq "Performance scans the remote node directly" "$(rp_env PAYOUT_NODE_REMOTE)|$(rp_env PAYOUT_NODE_PROXY)" "true|"

seed_env
rp_config privacy remote node.example.com
out="$(rp_apply)"
assert_rc "Privacy applies a public remote node through Tor" "$?" 0
assert_eq "Privacy routes the payout scan through the Tor SOCKS port" "$(rp_env PAYOUT_NODE_REMOTE)|$(rp_env PAYOUT_NODE_PROXY)" "true|172.28.0.25:9050"

seed_env
rp_config privacy remote 192.168.1.5
before="$(sha256sum "$V/.env")"
out="$(rp_apply)"
assert_rc "Privacy refuses a node Tor cannot reach" "$?" 1
assert_contains "Privacy refusal names the limitation and the node" "$out" 'Tor cannot reach monero.remote.host "192.168.1.5"'
assert_eq "Privacy refusal leaves the rendered environment untouched" "$(sha256sum "$V/.env")" "$before"
assert_not_contains "Privacy refusal never prints the view key" "$out" "$PAYOUT_VIEW1"

seed_env
rp_config privacy remote 192.168.1.5 ""
out="$(rp_apply)"
assert_rc "Privacy without a view key keeps a LAN remote node working" "$?" 0
assert_eq "remote node without a view key renders no wallet" "$(rp_env PAYOUT_CONFIRM_ENABLED)|$(rp_env PAYOUT_NODE_REMOTE)|$(rp_env COMPOSE_PROFILES)" "false||"

seed_env
rp_config balance local "" ""
out="$(rp_apply)"
assert_eq "local node without a view key renders no wallet" "$(rp_env PAYOUT_CONFIRM_ENABLED)|$(rp_env COMPOSE_PROFILES)" "false|local_node"
seed_env
rp_config balance local ""
out="$(rp_apply)"
assert_eq "local node with a view key keeps the bundled node route" "$(rp_env PAYOUT_NODE_REMOTE)|$(rp_env PAYOUT_NODE_PROXY)|$(rp_env COMPOSE_PROFILES)" "||local_node,payout_confirm"

seed_env
rp_config balance local "" ""
jq --arg k "$PAYOUT_VIEW1" --arg s "$PAYOUT_TARI_PUBLIC1" '.tari.mode="remote" | .tari.remote={host:"tari.example.com"} | .tari.view_key=$k | .tari.spend_public_key=$s' "$V/config.json" >"$V/candidate"
mv "$V/candidate" "$V/config.json"
out="$(rp_apply)"
assert_rc "a Tari view key with a remote Tari node stays refused" "$?" 1
assert_contains "the Tari refusal names the Monero-only limitation" "$out" "supported for Monero only"

rp_preview() { PAYOUT_NODE_REMOTE=true MONERO_REMOTE_HOST="$1" MONERO_REMOTE_RPC_PORT=28081 PAYOUT_NODE_PROXY="$2" run_sourced "$SANDBOX" describe_change "${@:3}"; }
out="$(rp_preview 192.168.1.5 "" PAYOUT_NODE_REMOTE false true)"
assert_contains "the remote payout preview needs confirmation" "$out" "CONFIRM"
assert_contains "the direct preview names the node and route" "$out" "the remote Monero node 192.168.1.5:28081 directly, not through Tor"
assert_contains "the preview discloses what the node operator can do" "$out" "can hide or misreport payouts"
out="$(rp_preview node.example.com 172.28.0.25:9050 PAYOUT_NODE_REMOTE false true)"
assert_contains "the Tor preview names the node and route" "$out" "the remote Monero node node.example.com:28081 through Tor"
out="$(rp_preview 2001:db8::1 "" MONERO_VIEW_KEY "" "$PAYOUT_VIEW1")"
assert_contains "setting the key previews the remote node it will scan" "$out" "scans for confirmed payouts through the remote Monero node [2001:db8::1]:28081 directly"
assert_not_contains "the key preview never prints the key" "$out" "$PAYOUT_VIEW1"
out="$(rp_preview 192.168.1.5 "" PAYOUT_NODE_REMOTE true false)"
assert_contains "leaving remote mode previews the local node" "$out" "return to the local Monero node"
out="$(MONERO_REMOTE_HOST="" PAYOUT_NODE_REMOTE=false run_sourced "$SANDBOX" describe_change MONERO_VIEW_KEY "" "$PAYOUT_VIEW1")"
assert_contains "the local preview still names the local node" "$out" "scans for confirmed payouts through the local Monero node"
