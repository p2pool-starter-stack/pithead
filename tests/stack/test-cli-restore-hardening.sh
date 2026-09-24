# shellcheck shell=bash
: "${STACK_SUITE:?is unset: this file is a tests/stack/run.sh fragment, not a script — run tests/stack/run.sh}"
echo "== black-box: administrative restore stages and constrains archives =="
CR="$SANDBOX/cli-restore"
ROOTS="$CR/roots"
mkdir -p "$ROOTS/${BK#/}/data/tor" "$ROOTS/${BK#/}/data/dashboard" "$CR/tmp"
cp "$BK/config.json" "$BK/.env" "$ROOTS/${BK#/}/"
printf 'CADDY-SAFE\n' >"$ROOTS/${BK#/}/Caddyfile"
printf 'KEY-SAFE\n' >"$ROOTS/${BK#/}/data/tor/hs_ed25519_secret_key"
printf 'DB-SAFE\n' >"$ROOTS/${BK#/}/data/dashboard/dashboard.db"
chmod 644 "$ROOTS/${BK#/}/config.json" "$ROOTS/${BK#/}/.env" \
    "$ROOTS/${BK#/}/Caddyfile" "$ROOTS/${BK#/}/data/tor/hs_ed25519_secret_key" \
    "$ROOTS/${BK#/}/data/dashboard/dashboard.db"
CR_ARCHIVE="$CR/valid.tar.gz"
cr_archive() {
    tar -czf "$1" -C "$ROOTS" "${BK#/}/config.json" "${BK#/}/.env" "${BK#/}/Caddyfile" "${BK#/}/data/tor" "${BK#/}/data/dashboard"
}
cr_archive "$CR_ARCHIVE"

# Staging derives files privately: it must not refresh the live wallet sidecar before commit.
printf 'LIVE-WALLET-SIDECAR\n' >"$BK/data/tari-wallet-secret.env"
out="$(cd "$BK" && PATH="$BK/bin:$PATH" run_sourced "$BK" eval 'RESTORE_STAGE_DIR=$(mktemp -d); trap restore_discard_stage EXIT; restore_stage_archive "$CR_ARCHIVE" 0 ""' 2>&1)"
assert_rc "restore stages derived files successfully" "$?" 0
assert_eq "staging leaves the live wallet sidecar untouched" "$(cat "$BK/data/tari-wallet-secret.env")" LIVE-WALLET-SIDECAR

cat >"$BK/bin/docker" <<'EOF'
#!/usr/bin/env bash
case "$*" in
"compose ps --status "*)
    n=0
    [ -z "${PS_COUNT:-}" ] || { [ ! -f "$PS_COUNT" ] || n=$(cat "$PS_COUNT"); n=$((n + 1)); printf '%s' "$n" >"$PS_COUNT"; }
    { [ -z "${ACTIVE_AFTER_PS_COUNT:-}" ] || [ "$n" -gt "$ACTIVE_AFTER_PS_COUNT" ]; } &&
        [ "$*" = "compose ps --status ${STACK_STATUS:-stopped} -q" ] && echo cid123
    ;;
esac
exit 0
EOF
chmod +x "$BK/bin/docker"

out="$(cd "$BK" && STACK_STATUS=paused PATH="$BK/bin:$PATH" ./pithead restore -y "$CR_ARCHIVE" 2>&1)"
assert_rc "restore refuses a paused service" "$?" 1
assert_contains "live restore names the stop requirement" "$out" "pithead down"

printf 'CADDY-LIVE\n' >"$BK/Caddyfile"
rm -f "$CR/ps.count"
out="$(cd "$BK" && PS_COUNT="$CR/ps.count" ACTIVE_AFTER_PS_COUNT=3 STACK_STATUS=running PATH="$BK/bin:$PATH" ./pithead restore -y "$CR_ARCHIVE" 2>&1)"
assert_rc "restore rechecks service state under its lock" "$?" 1
assert_eq "late service start prevents commit" "$(cat "$BK/Caddyfile")" CADDY-LIVE

mkdir -p "$ROOTS/${SANDBOX#/}"
printf ATTACK >"$ROOTS/${SANDBOX#/}/victim"
tar -czf "$CR/outside.tar.gz" -C "$ROOTS" "${BK#/}/config.json" "${BK#/}/.env" "${SANDBOX#/}/victim"
out="$(cd "$BK" && PATH="$BK/bin:$PATH" ./pithead restore -y "$CR/outside.tar.gz" 2>&1)"
assert_rc "restore rejects a regular member outside its destination set" "$?" 1
assert_contains "outside-member refusal names the boundary" "$out" "outside this appliance"

mkdir "$CR/swap-bin"
cat >"$CR/swap-bin/cp" <<'EOF'
#!/usr/bin/env bash
/bin/cp "$@" || exit
[ "${1:-}" != -- ] || shift
[ "$1" != "$SNAPSHOT_SOURCE" ] || { /bin/cp "$SWAP_ARCHIVE" "$SNAPSHOT_SOURCE"; : >"$SWAP_MARKER"; }
EOF
chmod +x "$CR/swap-bin/cp"
out="$(cd "$BK" && SNAPSHOT_SOURCE="$CR_ARCHIVE" SWAP_ARCHIVE="$CR/outside.tar.gz" SWAP_MARKER="$CR/swapped" PATH="$CR/swap-bin:$BK/bin:$PATH" ./pithead restore -y "$CR_ARCHIVE" 2>&1)"
assert_rc "restore validates and extracts one private archive snapshot" "$?" 0
assert_eq "snapshot regression actually swaps the source archive" "$(test -f "$CR/swapped" && echo yes)" yes
cr_archive "$CR_ARCHIVE"

mkdir -p "$CR/wrong/${BK#/}"
cp "$BK/config.json" "$BK/.env" "$CR/wrong/${BK#/}/"
mkdir "$CR/wrong/${BK#/}/Caddyfile"
tar -czf "$CR/wrong-type.tar.gz" -C "$CR/wrong" "${BK#/}"
out="$(cd "$BK" && PATH="$BK/bin:$PATH" ./pithead restore -y "$CR/wrong-type.tar.gz" 2>&1)"
assert_rc "restore rejects a directory in place of Caddyfile" "$?" 1

printf VICTIM >"$CR/victim"
rm -f "$BK/data/tor/hs_ed25519_secret_key"
ln -s "$CR/victim" "$BK/data/tor/hs_ed25519_secret_key"
out="$(cd "$BK" && PATH="$BK/bin:$PATH" ./pithead restore -y "$CR_ARCHIVE" 2>&1)"
assert_rc "restore rejects a nested destination symlink" "$?" 1
assert_eq "nested destination victim stays untouched" "$(cat "$CR/victim")" VICTIM
rm -f "$BK/data/tor/hs_ed25519_secret_key"

printf '{bad json' >"$ROOTS/${BK#/}/config.json"
cr_archive "$CR/bad-config.tar.gz"
mkdir "$CR/inherited-stage"
printf KEEP >"$CR/inherited-stage/victim"
out="$(cd "$BK" && TMPDIR="$CR/tmp" RESTORE_STAGE_DIR="$CR/inherited-stage" PATH="$BK/bin:$PATH" ./pithead restore -y "$CR/bad-config.tar.gz" 2>&1)"
assert_rc "invalid staged config is refused" "$?" 1
assert_eq "failed restore removes its private stage" "$(find "$CR/tmp" -mindepth 1 -print -quit)" ""
assert_eq "restore never removes an inherited stage path" "$(cat "$CR/inherited-stage/victim")" KEEP

cp "$BK/config.json" "$ROOTS/${BK#/}/config.json"
jq '.ssh = {"enabled":true}' "$ROOTS/${BK#/}/config.json" >"$ROOTS/${BK#/}/config.json.tmp" && mv "$ROOTS/${BK#/}/config.json.tmp" "$ROOTS/${BK#/}/config.json"
cr_archive "$CR/retired-ssh.tar.gz"
out="$(cd "$BK" && PITHEAD_APPLIANCE=1 PATH="$BK/bin:$PATH" ./pithead restore -y "$CR/retired-ssh.tar.gz" 2>&1)"
assert_rc "release restore rejects newly staged SSH config" "$?" 1
assert_contains "release restore names retired SSH" "$out" "ssh.enabled is unavailable"
cp "$BK/config.json" "$ROOTS/${BK#/}/config.json"
chmod 644 "$ROOTS/${BK#/}/config.json"
cr_archive "$CR_ARCHIVE"
rm -f "$CR/sudo.log"
out="$(cd "$BK" && SUDO_LOG="$CR/sudo.log" PATH="$BK/bin:$PATH" ./pithead restore -y "$CR_ARCHIVE" 2>&1)"
assert_rc "validated administrative restore succeeds" "$?" 0
assert_contains "fixed-file install retains the invoking uid" "$(cat "$CR/sudo.log")" "install -o $(id -u) -g $(id -g) -m 600"
assert_eq "restored config is owner-only" "$(file_mode "$BK/config.json")" 600
assert_eq "restored env is owner-only" "$(file_mode "$BK/.env")" 600
# #2329: the Caddyfile must come back world-readable like the normal apply path renders it — a
# cap_drop:ALL caddy container has no CAP_DAC_OVERRIDE and cannot read a 600 file it doesn't own,
# so a 600 restore leaves caddy permission-denied on its bind-mounted Caddyfile for the rest of
# the appliance's life.
assert_contains "Caddyfile install does not carry the secret-file mode" "$(cat "$CR/sudo.log")" "install -o $(id -u) -g $(id -g) -m 644"
assert_eq "restored Caddyfile is world-readable" "$(file_mode "$BK/Caddyfile")" 644
assert_eq "restored config belongs to the invoking operator" "$(file_uid "$BK/config.json")" "$(id -u)"
assert_eq "restored onion key is owner-only" "$(file_mode "$BK/data/tor/hs_ed25519_secret_key")" 600
assert_eq "restored database is owner-only" "$(file_mode "$BK/data/dashboard/dashboard.db")" 600

# Generated files in a backup are compatibility inputs, never runtime policy. A valid config plus
# stale .env/Caddyfile must land the normal writers' output, while opaque generated identity and
# secrets still round-trip.
# Dashboard auth is generated from the password, so it is built here rather than written literally.
CR_DASH_FP=$(printf '%s' fixture-dashboard-pass | sha256sum | cut -d' ' -f1)
CR_DASH_HASH=$(printf '$2y$14$%s' "$(printf 'U%.0s' {1..53})" | openssl base64 -A)
jq '.p2pool.stratum_password = "fixture.literal-pass" | .dashboard.auth = {"username":"admin","password":"fixture-dashboard-pass"}' "$BK/config.json" >"$ROOTS/${BK#/}/config.json"
cat >"$ROOTS/${BK#/}/.env" <<'EOF'
PROXY_AUTH_TOKEN=abcdef0123456789abcdef01
WALLET_RPC_PASSWORD=111111111111111111111111
TARI_WALLET_PASSWORD=22222222222222222222222222222222
PROXY_STRATUM_PASSWORD=fixture.literal-pass
MONERO_ONION_ADDRESS=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa.onion
TARI_ONION_ADDRESS=bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb.onion
P2POOL_ONION_ADDRESS=cccccccccccccccccccccccccccccccccccccccccccccccccccccccc.onion
DASHBOARD_ONION_ADDRESS=dddddddddddddddddddddddddddddddddddddddddddddddddddddddd.onion
DASHBOARD_ONION_CLIENT_PUBKEY=AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
DASHBOARD_ONION_CLIENT_PRIVKEY=BBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB
ARCHIVE_ONLY_VALUE=stale-generated-setting
DEPLOYMENT_COMPLETED=true
EOF
printf 'DASHBOARD_AUTH_HASH_B64=%s\nDASHBOARD_AUTH_PW_FP=%s\n' "$CR_DASH_HASH" "$CR_DASH_FP" >>"$ROOTS/${BK#/}/.env"
printf 'STALE-GENERATED-CADDY\n' >"$ROOTS/${BK#/}/Caddyfile"
cr_archive "$CR/stale-derived.tar.gz"
out="$(cd "$BK" && PATH="$BK/bin:$PATH" ./pithead restore -y "$CR/stale-derived.tar.gz" 2>&1)"
assert_rc "restore accepts valid config while discarding archive-derived policy" "$?" 0
assert_eq "restore derives literal stratum password from config" "$(sed -n 's/^PROXY_STRATUM_PASSWORD=//p' "$BK/.env")" fixture.literal-pass
assert_eq "administrative restore retains deployment status" "$(sed -n 's/^DEPLOYMENT_COMPLETED=//p' "$BK/.env")" true
assert_eq "restore preserves the generated proxy secret" "$(sed -n 's/^PROXY_AUTH_TOKEN=//p' "$BK/.env")" abcdef0123456789abcdef01
assert_eq "restore preserves the wallet RPC secret" "$(sed -n 's/^WALLET_RPC_PASSWORD=//p' "$BK/.env")" 111111111111111111111111
assert_eq "restore preserves the wallet database secret" "$(sed -n 's/^TARI_WALLET_PASSWORD=//p' "$BK/.env")" 22222222222222222222222222222222
assert_eq "restore preserves the dashboard auth hash" "$(sed -n 's/^DASHBOARD_AUTH_HASH_B64=//p' "$BK/.env")" "$CR_DASH_HASH"
assert_eq "restore preserves the dashboard auth fingerprint" "$(sed -n 's/^DASHBOARD_AUTH_PW_FP=//p' "$BK/.env")" "$CR_DASH_FP"
assert_eq "restore preserves the Tor onion identity" "$(sed -n 's/^MONERO_ONION_ADDRESS=//p' "$BK/.env")" aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa.onion
assert_eq "restore preserves onion client-auth identity" "$(sed -n 's/^DASHBOARD_ONION_CLIENT_PRIVKEY=//p' "$BK/.env")" BBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB
CR_KEPT='^(PROXY_AUTH_TOKEN|WALLET_RPC_PASSWORD|TARI_WALLET_PASSWORD|[A-Z0-9]+_ONION_ADDRESS|DASHBOARD_ONION_CLIENT_(PUB|PRIV)KEY|DASHBOARD_AUTH_(HASH_B64|PW_FP))='
assert_eq "restore preserves every archived secret and identity exactly" "$(grep -E "$CR_KEPT" "$BK/.env" | sort)" "$(grep -E "$CR_KEPT" "$ROOTS/${BK#/}/.env" | sort)"
assert_not_contains "restore drops unrecognized archive env policy" "$(cat "$BK/.env")" ARCHIVE_ONLY_VALUE
assert_contains "restore regenerates the dashboard proxy target" "$(cat "$BK/Caddyfile")" "reverse_proxy 127.0.0.1:8000"
assert_not_contains "restore discards stale generated Caddy policy" "$(cat "$BK/Caddyfile")" STALE-GENERATED-CADDY

# An `auto` stratum password was generated once; restore keeps the archived value, never a new one.
jq '.p2pool.stratum_password = "auto"' "$ROOTS/${BK#/}/config.json" >"$ROOTS/${BK#/}/config.json.tmp" && mv "$ROOTS/${BK#/}/config.json.tmp" "$ROOTS/${BK#/}/config.json"
sed 's/^PROXY_STRATUM_PASSWORD=.*/PROXY_STRATUM_PASSWORD=333333333333333333333333/' "$ROOTS/${BK#/}/.env" >"$ROOTS/${BK#/}/.env.tmp" && mv "$ROOTS/${BK#/}/.env.tmp" "$ROOTS/${BK#/}/.env"
cr_archive "$CR/auto-stratum.tar.gz"
out="$(cd "$BK" && PATH="$BK/bin:$PATH" ./pithead restore -y "$CR/auto-stratum.tar.gz" 2>&1)"
assert_rc "restore accepts an archived generated stratum password" "$?" 0
assert_eq "restore preserves the generated stratum password" "$(sed -n 's/^PROXY_STRATUM_PASSWORD=//p' "$BK/.env")" 333333333333333333333333
jq '.p2pool.stratum_password = "fixture.literal-pass"' "$ROOTS/${BK#/}/config.json" >"$ROOTS/${BK#/}/config.json.tmp" && mv "$ROOTS/${BK#/}/config.json.tmp" "$ROOTS/${BK#/}/config.json"
sed 's/^PROXY_STRATUM_PASSWORD=.*/PROXY_STRATUM_PASSWORD=fixture.literal-pass/' "$ROOTS/${BK#/}/.env" >"$ROOTS/${BK#/}/.env.tmp" && mv "$ROOTS/${BK#/}/.env.tmp" "$ROOTS/${BK#/}/.env"

# A password changed after the last render leaves a stale pair: the old hash must not survive, or
# the old password would keep opening the dashboard. The render rehashes through the fake Caddy.
jq '.dashboard.auth.password = "other-dashboard-pass"' "$ROOTS/${BK#/}/config.json" >"$ROOTS/${BK#/}/config.json.tmp" && mv "$ROOTS/${BK#/}/config.json.tmp" "$ROOTS/${BK#/}/config.json"
cr_archive "$CR/stale-dashboard-auth.tar.gz"
printf 'services: {caddy: {image: caddy:2.0.0@sha256:%064d}}\n' 0 >"$BK/docker-compose.yml"
mkdir -p "$CR/hashbin"
cat >"$CR/hashbin/docker" <<EOF
#!/usr/bin/env bash
case "\$*" in *hash-password*) printf '\$2y\$14\$%s\n' "$(printf 'R%.0s' {1..53})" ;; *) exec "$BK/bin/docker" "\$@" ;; esac
EOF
chmod +x "$CR/hashbin/docker"
out="$(cd "$BK" && PATH="$CR/hashbin:$BK/bin:$PATH" ./pithead restore -y "$CR/stale-dashboard-auth.tar.gz" 2>&1)"
assert_rc "restore accepts a dashboard password changed since the last render" "$?" 0
assert_not_contains "restore drops a dashboard hash for another password" "$(cat "$BK/.env")" "$CR_DASH_HASH"
assert_contains "restore rehashes the configured dashboard password" "$(cat "$BK/.env")" "DASHBOARD_AUTH_HASH_B64=$(printf '$2y$14$%s' "$(printf 'R%.0s' {1..53})" | openssl base64 -A)"
assert_eq "restore fingerprints the configured dashboard password" "$(sed -n 's/^DASHBOARD_AUTH_PW_FP=//p' "$BK/.env")" "$(printf '%s' other-dashboard-pass | sha256sum | cut -d' ' -f1)"
jq '.dashboard.auth.password = "fixture-dashboard-pass"' "$ROOTS/${BK#/}/config.json" >"$ROOTS/${BK#/}/config.json.tmp" && mv "$ROOTS/${BK#/}/config.json.tmp" "$ROOTS/${BK#/}/config.json"

# A hash that is not well-formed bcrypt (an older release's, or a damaged one) must not survive,
# nor block the restore: it is dropped and the configured password is hashed again.
CR_REHASH="DASHBOARD_AUTH_HASH_B64=$(printf '$2y$14$%s' "$(printf 'R%.0s' {1..53})" | openssl base64 -A)"
for cr_bad in not-bcrypt trailing-text; do
    case "$cr_bad" in not-bcrypt) cr_value=$(printf 'not-bcrypt' | openssl base64 -A) ;; *) cr_value="$CR_DASH_HASH}" ;; esac
    sed "s/^DASHBOARD_AUTH_HASH_B64=.*/DASHBOARD_AUTH_HASH_B64=$cr_value/" "$ROOTS/${BK#/}/.env" >"$ROOTS/${BK#/}/.env.tmp" && mv "$ROOTS/${BK#/}/.env.tmp" "$ROOTS/${BK#/}/.env"
    cr_archive "$CR/malformed-dashboard-hash.tar.gz"
    out="$(cd "$BK" && PATH="$CR/hashbin:$BK/bin:$PATH" ./pithead restore -y "$CR/malformed-dashboard-hash.tar.gz" 2>&1)"
    assert_rc "restore accepts a malformed dashboard hash ($cr_bad)" "$?" 0
    assert_contains "restore rehashes over a malformed dashboard hash ($cr_bad)" "$(cat "$BK/.env")" "$CR_REHASH"
    assert_eq "restore keeps the matching fingerprint over a malformed hash ($cr_bad)" "$(sed -n 's/^DASHBOARD_AUTH_PW_FP=//p' "$BK/.env")" "$CR_DASH_FP"
done
rm -f "$BK/docker-compose.yml"
sed "s/^DASHBOARD_AUTH_HASH_B64=.*/DASHBOARD_AUTH_HASH_B64=$CR_DASH_HASH/" "$ROOTS/${BK#/}/.env" >"$ROOTS/${BK#/}/.env.tmp" && mv "$ROOTS/${BK#/}/.env.tmp" "$ROOTS/${BK#/}/.env"

printf 'LIVE-ENV\n' >"$BK/.env"
printf 'LIVE-CADDY\n' >"$BK/Caddyfile"
cat >>"$ROOTS/${BK#/}/.env" <<'EOF'
PROXY_AUTH_TOKEN=111111111111111111111111
EOF
cr_archive "$CR/duplicate-preserved.tar.gz"
out="$(cd "$BK" && PATH="$BK/bin:$PATH" ./pithead restore -y "$CR/duplicate-preserved.tar.gz" 2>&1)"
assert_rc "restore rejects duplicate preserved-secret keys" "$?" 1
assert_contains "duplicate preserved-secret refusal names invalid state" "$out" "invalid generated identity or secret state"
assert_eq "duplicate preserved-secret refusal leaves live env untouched" "$(cat "$BK/.env")" LIVE-ENV
assert_eq "duplicate preserved-secret refusal leaves live Caddyfile untouched" "$(cat "$BK/Caddyfile")" LIVE-CADDY

grep -v '^PROXY_AUTH_TOKEN=' "$ROOTS/${BK#/}/.env" >"$ROOTS/${BK#/}/.env.tmp"
printf 'PROXY_AUTH_TOKEN=not-generated\n' >>"$ROOTS/${BK#/}/.env.tmp"
mv "$ROOTS/${BK#/}/.env.tmp" "$ROOTS/${BK#/}/.env"
cr_archive "$CR/malformed-preserved.tar.gz"
out="$(cd "$BK" && PATH="$BK/bin:$PATH" ./pithead restore -y "$CR/malformed-preserved.tar.gz" 2>&1)"
assert_rc "restore rejects malformed preserved-secret values" "$?" 1
assert_eq "malformed preserved-secret refusal leaves live env untouched" "$(cat "$BK/.env")" LIVE-ENV
unset -f cr_archive
unset CR ROOTS CR_ARCHIVE CR_DASH_FP CR_DASH_HASH CR_KEPT CR_REHASH cr_bad cr_value out
