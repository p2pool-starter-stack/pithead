# shellcheck shell=bash
: "${STACK_SUITE:?is unset: source test-dashboard.sh before this fragment}"
echo "== black-box: dashboard auth lifecycle (#3872) =="
auth_native_dir=$(mktemp -d /tmp/pithead-auth-owner.XXXXXX)
chmod 755 "$auth_native_dir"
(
    # shellcheck source=/dev/null
    cd "$SANDBOX" && source "$STACK" 2>/dev/null
    DASHBOARD_AUTH_USER=admin DASHBOARD_LEGACY_AUTH_HASH='' DASHBOARD_METRICS_PASSWORD_HASH='' \
        DASHBOARD_AUTH_USERS_JSON='[{"name":"owner","role":"admin","password_hash":"$2y$12$AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA"}]' \
        render_dashboard_auth "$auth_native_dir"
)
assert_eq "auth directory is owned by the dashboard uid" "$(stat -c %u "$auth_native_dir/auth")" "1000"
sudo setpriv --reuid 1000 --regid 1000 --clear-groups cat "$auth_native_dir/auth/auth.json" >/dev/null &&
    ok "dashboard uid can traverse and read the auth file" || bad "dashboard uid can traverse and read the auth file" "uid 1000 could not read it"
sudo rm -rf "$auth_native_dir"
cp "$ROOT/docker-compose.yml" "$V/docker-compose.yml"
mkdir -p "$V/dashboard" && : >"$V/dashboard/Dockerfile"
AUTH_LOG="$V/auth-docker.log"
seed_env
printf '{ "monero": {"mode":"local","wallet_address":"%s","node_username":"u","node_password":"p"}, "tari":{"wallet_address":"'"$VALID_TARI"'"}, "p2pool":{"pool":"main"}, "proxy":{"donate_level":0}, "dashboard":{"secure":true,"host":"box.lan","auth":{"username":"admin","password":"hunter2hunter2"}} }\n' "$WALLET" >"$V/config.json"
: >"$AUTH_LOG"
(cd "$V" && DOCKER_LOG="$AUTH_LOG" PATH="$V/bin:$PATH" ./pithead apply -y) >/dev/null 2>&1
assert_rc "auth enable applies cleanly" "$?" "0"
assert_eq "auth username persisted" "$(run_sourced "$V" env_get_file "$V/.env" DASHBOARD_AUTH_USER)" "admin"
hash1="$(run_sourced "$V" env_get_file "$V/.env" DASHBOARD_AUTH_HASH_B64)"
fp1="$(run_sourced "$V" env_get_file "$V/.env" DASHBOARD_AUTH_PW_FP)"
[ -n "$hash1" ] && ok "auth hash persisted" || bad "auth hash persisted" "empty"
assert_contains "auth hashing disables container logs" "$(cat "$AUTH_LOG")" "run --rm -i --log-driver none "
assert_not_contains "auth password stays out of docker argv" "$(cat "$AUTH_LOG")" "hunter2hunter2"
assert_not_contains "Caddyfile contains no basic_auth" "$(cat "$V/Caddyfile")" "basic_auth"
assert_eq "dashboard receives auth file path" "$(run_sourced "$V" env_get_file "$V/.env" DASHBOARD_AUTH_FILE)" "/control/auth/auth.json"
assert_eq "legacy password becomes an admin" "$(jq -r '.users[0] | [.name,.role] | join(":")' "$V/data/control/auth/auth.json")" "admin:admin"
assert_eq "auth file carries stable hash" "$(jq -jr '.users[0].password_hash' "$V/data/control/auth/auth.json" | openssl base64 -A)" "$hash1"
auth_revision1=$(jq -r '.users[0].revision' "$V/data/control/auth/auth.json")
[ -n "$auth_revision1" ] && ok "auth file records a session revision" || bad "auth file records a session revision" "empty"
assert_eq "auth file is owner-only" "$(stat -c %a "$V/data/control/auth/auth.json")" "600"
assert_not_contains "auth plaintext never persisted" "$(cat "$V/.env" "$V/Caddyfile")" "hunter2hunter2"
auth_before_cancel=$(sha256sum "$V/data/control/auth/auth.json" | cut -d' ' -f1)
cancel_password=$(openssl rand -hex 12)
printf '{ "monero": {"mode":"local","wallet_address":"%s","node_username":"u","node_password":"p"}, "tari":{"wallet_address":"%s"}, "p2pool":{"pool":"main"}, "proxy":{"donate_level":1}, "dashboard":{"secure":true,"host":"box.lan","auth":{"username":"admin","password":"%s"}} }\n' "$WALLET" "$VALID_TARI" "$cancel_password" >"$V/config.json"
printf 'n\n' | (cd "$V" && DOCKER_LOG="$AUTH_LOG" PATH="$V/bin:$PATH" ./pithead apply) >/dev/null 2>&1 || true
assert_eq "cancelled apply leaves live auth byte-identical" "$(sha256sum "$V/data/control/auth/auth.json" | cut -d' ' -f1)" "$auth_before_cancel"
unset cancel_password
printf '{ "monero": {"mode":"local","wallet_address":"%s","node_username":"u","node_password":"p"}, "tari":{"wallet_address":"'"$VALID_TARI"'"}, "p2pool":{"pool":"main"}, "proxy":{"donate_level":1}, "dashboard":{"secure":true,"host":"box.lan","auth":{"username":"admin","password":"hunter2hunter2"}} }\n' "$WALLET" >"$V/config.json"
: >"$AUTH_LOG"
(cd "$V" && DOCKER_LOG="$AUTH_LOG" PATH="$V/bin:$PATH" ./pithead apply -y) >/dev/null 2>&1
assert_rc "unchanged auth applies cleanly" "$?" "0"
assert_eq "unchanged password keeps the hash" "$(run_sourced "$V" env_get_file "$V/.env" DASHBOARD_AUTH_HASH_B64)" "$hash1"
assert_eq "unchanged user keeps revision" "$(jq -r '.users[0].revision' "$V/data/control/auth/auth.json")" "$auth_revision1"
assert_not_contains "unchanged password is not re-hashed" "$(cat "$AUTH_LOG")" "hash-password"
printf '{ "monero": {"mode":"local","wallet_address":"%s","node_username":"u","node_password":"p"}, "tari":{"wallet_address":"'"$VALID_TARI"'"}, "p2pool":{"pool":"main"}, "proxy":{"donate_level":1}, "dashboard":{"secure":true,"host":"box.lan","auth":{"username":"admin","password":"freshpass99"}} }\n' "$WALLET" >"$V/config.json"
: >"$AUTH_LOG"
(cd "$V" && DOCKER_LOG="$AUTH_LOG" PATH="$V/bin:$PATH" ./pithead apply -y) >/dev/null 2>&1
assert_rc "changed auth applies cleanly" "$?" "0"
assert_contains "changed password re-hashes" "$(cat "$AUTH_LOG")" "hash-password"
assert_eq "changed password updates fingerprint" "$([ "$(run_sourced "$V" env_get_file "$V/.env" DASHBOARD_AUTH_PW_FP)" != "$fp1" ] && echo changed)" "changed"
assert_eq "changed password rotates revision" "$([ "$(jq -r '.users[0].revision' "$V/data/control/auth/auth.json")" != "$auth_revision1" ] && echo changed)" "changed"
assert_contains "auth change recreates dashboard" "$(cat "$AUTH_LOG")" "compose up --pull never -d --remove-orphans"
assert_contains "auth change builds dashboard first" "$(cat "$AUTH_LOG")" "--build --no-deps dashboard"
printf '{ "monero": {"mode":"local","wallet_address":"%s","node_username":"u","node_password":"p"}, "tari":{"wallet_address":"'"$VALID_TARI"'"}, "p2pool":{"pool":"main"}, "proxy":{"donate_level":1}, "dashboard":{"secure":true,"host":"box.lan"} }\n' "$WALLET" >"$V/config.json"
(cd "$V" && DOCKER_LOG="$AUTH_LOG" PATH="$V/bin:$PATH" ./pithead apply -y) >/dev/null 2>&1
assert_rc "auth disable applies cleanly" "$?" "0"
assert_eq "auth disable clears the hash" "$(run_sourced "$V" env_get_file "$V/.env" DASHBOARD_AUTH_HASH_B64)" ""
assert_not_contains "auth disable drops basic_auth" "$(cat "$V/Caddyfile")" "basic_auth"
