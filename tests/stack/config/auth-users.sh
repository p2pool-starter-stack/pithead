# shellcheck shell=bash
: "${STACK_SUITE:?is unset: source test-config.sh before this fragment}"
echo "== black-box: named dashboard authentication (#3872) =="
assert_contains "auth fingerprint preview names the standby credential" \
    "$(run_sourced "$SANDBOX" describe_change DASHBOARD_AUTH_CONFIG_FP old new)" "standby credential"
auth_bcrypt='$2y$12$AAAAAAAAAAAAAAAAAAAAA.AAAAAAAAAAAAAAAAAAAAAAAAAAAAAA.'
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
    '{monero:{mode:"local",wallet_address:$wallet,node_username:"u",node_password:"p"},tari:{wallet_address:$tari},p2pool:{pool:"main"},dashboard:{auth:{users:[{name:"owner",role:"admin",password_hash:$hash},{name:"watcher",role:"viewer",password_hash:$hash}],metrics_password_hash:$hash,standby_password_hash:$hash}}}' >"$V/config.json"
out="$(cd "$V" && PATH="$V/bin:$PATH" ./pithead apply -y 2>&1)"
assert_rc "explicit admin, viewer and metrics credentials apply" "$?" "0"
assert_eq "auth file renders both named users" "$(jq -r '.users | map(.name) | join(",")' "$V/data/control/auth/auth.json")" "owner,watcher"
assert_eq "auth file renders metrics hash" "$(jq -r '.metrics_password_hash' "$V/data/control/auth/auth.json")" "$auth_bcrypt"
assert_eq "auth file renders standby hash" "$(jq -r '.standby_password_hash' "$V/data/control/auth/auth.json")" "$auth_bcrypt"
seed_env
auth_bcrypt_2a="\$2a${auth_bcrypt#\$2y}"
auth_bcrypt_2b="\$2b${auth_bcrypt#\$2y}"
jq -n --arg wallet "$WALLET" --arg tari "$VALID_TARI" --arg hash_2a "$auth_bcrypt_2a" \
    --arg hash_2b "$auth_bcrypt_2b" --arg hash_2y "$auth_bcrypt" \
    '{monero:{mode:"local",wallet_address:$wallet,node_username:"u",node_password:"p"},tari:{wallet_address:$tari},p2pool:{pool:"main"},dashboard:{auth:{users:[{name:"owner",role:"admin",password_hash:$hash_2a}],metrics_password_hash:$hash_2b,standby_password_hash:$hash_2y}}}' >"$V/config.json"
out="$(cd "$V" && PATH="$V/bin:$PATH" ./pithead apply -y 2>&1)"
assert_rc "canonical bcrypt aliases apply across account and machine credentials" "$?" "0"
auth_masked="$V/data/control/masked/config.json"
PATH="$V/bin:$PATH" run_sourced "$V" render_masked_config "$V/data/control" >/dev/null 2>&1
assert_eq "standby hash is masked to the sentinel" "$(jq -c '.dashboard.auth.standby_password_hash' "$auth_masked")" '{"__secret__":true}'
assert_not_contains "masked config carries no raw standby hash" "$(cat "$auth_masked")" "$auth_bcrypt"
unset auth_masked
for invalid_hash in \
    '$2b$12$AAAAAAAAAAAAAAAAAAAAA/AAAAAAAAAAAAAAAAAAAAAAAAAAAAAA.' \
    '$2b$12$AAAAAAAAAAAAAAAAAAAAA.AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA'; do
    seed_env
    jq -n --arg wallet "$WALLET" --arg tari "$VALID_TARI" --arg hash "$invalid_hash" \
        '{monero:{mode:"local",wallet_address:$wallet,node_username:"u",node_password:"p"},tari:{wallet_address:$tari},p2pool:{pool:"main"},dashboard:{auth:{users:[{name:"owner",role:"admin",password_hash:$hash}]}}}' >"$V/config.json"
    out="$(cd "$V" && PATH="$V/bin:$PATH" ./pithead apply -y 2>&1)"
    assert_rc "noncanonical bcrypt encoding is rejected" "$?" "1"
done
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
