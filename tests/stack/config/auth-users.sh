# shellcheck shell=bash
: "${STACK_SUITE:?is unset: source test-config.sh before this fragment}"
echo "== black-box: named dashboard authentication (#3872) =="
auth_bcrypt='$2y$12$AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA'
seed_env
jq -n --arg wallet "$WALLET" --arg tari "$VALID_TARI" --arg hash "$auth_bcrypt" \
    '{monero:{mode:"local",wallet_address:$wallet,node_username:"u",node_password:"p"},tari:{wallet_address:$tari},p2pool:{pool:"main"},dashboard:{auth:{users:[{name:"watcher",role:"viewer",password_hash:$hash}]}}}' >"$V/config.json"
out="$(cd "$V" && PATH="$V/bin:$PATH" ./pithead apply -y 2>&1)"
assert_rc "viewer-only dashboard auth is rejected" "$?" "1"
assert_contains "viewer-only refusal requires an admin" "$out" "at least one admin"
seed_env
jq -n --arg wallet "$WALLET" --arg tari "$VALID_TARI" --arg hash "$auth_bcrypt" \
    '{monero:{mode:"local",wallet_address:$wallet,node_username:"u",node_password:"p"},tari:{wallet_address:$tari},p2pool:{pool:"main"},dashboard:{auth:{username:"admin",password:"longenough1",users:[{name:"admin",role:"viewer",password_hash:$hash}]}}}' >"$V/config.json"
out="$(cd "$V" && PATH="$V/bin:$PATH" ./pithead apply -y 2>&1)"
assert_rc "explicit users cannot shadow the legacy login" "$?" "1"
assert_contains "legacy-shadow refusal names the username" "$out" "cannot reuse dashboard.auth.username"
seed_env
jq -n --arg wallet "$WALLET" --arg tari "$VALID_TARI" --arg hash "$auth_bcrypt" \
    '{monero:{mode:"local",wallet_address:$wallet,node_username:"u",node_password:"p"},tari:{wallet_address:$tari},p2pool:{pool:"main"},dashboard:{auth:{users:[{name:"owner",role:"admin",password_hash:$hash},{name:"watcher",role:"viewer",password_hash:$hash}],metrics_password_hash:$hash}}}' >"$V/config.json"
out="$(cd "$V" && PATH="$V/bin:$PATH" ./pithead apply -y 2>&1)"
assert_rc "explicit admin, viewer and metrics credentials apply" "$?" "0"
assert_eq "auth file renders both named users" "$(jq -r '.users | map(.name) | join(",")' "$V/data/control/auth/auth.json")" "owner,watcher"
assert_eq "auth file renders metrics hash" "$(jq -r '.metrics_password_hash' "$V/data/control/auth/auth.json")" "$auth_bcrypt"
seed_env
jq -n --arg wallet "$WALLET" --arg tari "$VALID_TARI" --arg hash "$auth_bcrypt" \
    '{monero:{mode:"local",wallet_address:$wallet,node_username:"u",node_password:"p"},tari:{wallet_address:$tari},p2pool:{pool:"main"},dashboard:{onion:{enabled:true,client_auth:false},auth:{users:[{name:"owner",role:"admin",password_hash:$hash}]}}}' >"$V/config.json"
out="$(cd "$V" && PATH="$V/bin:$PATH" ./pithead apply -y 2>&1)"
assert_rc "named auth refuses a password-only onion" "$?" "1"
assert_contains "named onion refusal requires client auth" "$out" "dashboard.onion.client_auth must be true"
seed_env
jq -n --arg wallet "$WALLET" --arg tari "$VALID_TARI" \
    '{monero:{mode:"local",wallet_address:$wallet,node_username:"u",node_password:"p"},tari:{wallet_address:$tari},p2pool:{pool:"main"},dashboard:{control:{enabled:true}}}' >"$V/config.json"
out="$(cd "$V" && PATH="$V/bin:$PATH" ./pithead apply -y 2>&1)"
assert_rc "control without an authenticated admin is rejected" "$?" "1"
assert_contains "control refusal asks for an authenticated admin" "$out" "configure an authenticated admin"
seed_env
trace_password=$(openssl rand -hex 12)
jq -n --arg wallet "$WALLET" --arg tari "$VALID_TARI" --arg password "$trace_password" \
    '{monero:{mode:"local",wallet_address:$wallet,node_username:"u",node_password:"p"},tari:{wallet_address:$tari},p2pool:{pool:"main"},dashboard:{auth:{username:"admin",password:$password}}}' >"$V/config.json"
out="$(cd "$V" && PATH="$V/bin:$PATH" bash -x ./pithead apply -y 2>&1)"
case "$out" in
*"$trace_password"*) bad "legacy dashboard password stays out of xtrace" "legacy password was exposed" ;;
*) ok "legacy dashboard password stays out of xtrace" ;;
esac
unset trace_password
