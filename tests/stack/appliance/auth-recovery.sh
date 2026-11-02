# shellcheck shell=bash
: "${STACK_SUITE:?is unset: source test-appliance-media.sh before this fragment}"
# shellcheck source=os/overlay/pithead-media-config
source "$ROOT/os/overlay/pithead-media-config"

# shellcheck disable=SC2016
jq '.dashboard.auth={"username":"admin","password":"","users":[{"name":"admin","role":"admin","password_hash":"$2y$12$AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA"},{"name":"recovery","role":"viewer","password_hash":"$2y$12$BBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB"},{"name":"recovery-1","role":"viewer","password_hash":"$2y$12$CCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCC"}]}' "$MC/good.json" >"$MC/named-auth.json"
recovery_password=$(openssl rand -hex 12)
jq -n --arg password "$recovery_password" '{dashboard:{auth:{password:$password}}}' >"$MC/recovery-stick.json"
merged=$(media_merge_config "$MC/named-auth.json" "$MC/recovery-stick.json")
assert_eq "media password recovery chooses a noncolliding legacy name" \
    "$(jq -r '.dashboard.auth.username' "$merged")" "recovery-2"
assert_eq "media password recovery preserves named accounts" \
    "$(jq -r '.dashboard.auth.users | map(.name) | join(",")' "$merged")" "admin,recovery,recovery-1"
if jq -e --arg password "$recovery_password" '.dashboard.auth.password == $password' "$merged" >/dev/null; then
    ok "media password recovery keeps the replacement password"
else
    bad "media password recovery keeps the replacement password" "replacement password changed"
fi
validated=$(
    cd "$MC" || exit 1
    export PATH="$MC/bin:$PATH" PITHEAD_MEDIA_BIN="$MC/pithead"
    source "$ROOT/os/overlay/pithead-media-config"
    media_validate_config "$merged"
)
assert_eq "media password recovery remains a valid configuration" \
    "$(jq -r '.dashboard.auth.username' "$validated")" "recovery-2"
unset recovery_password
