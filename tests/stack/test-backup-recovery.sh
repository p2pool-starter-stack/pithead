# shellcheck shell=bash
: "${STACK_SUITE:?is unset: this file is a tests/stack/run.sh fragment, not a script — run tests/stack/run.sh}"
# Sourced by test-backup.sh: running-stack recovery and archive finalization failures.
echo "== black-box: backup failures recover a previously running stack (#551, #1965) =="
FB="$SANDBOX/failbackup"
mkdir -p "$FB/build/tari" "$FB/data/tor" "$FB/data/dashboard" "$FB/bin"
cp "$STACK" "$FB/pithead"
cp "$ROOT/build/tari/config.toml.template" "$FB/build/tari/"
cat >"$FB/bin/docker" <<'EOF'
#!/usr/bin/env bash
echo "[docker] $*" >>"${DOCKER_LOG:-/dev/null}"
case "$*" in
  "compose ps --status running -q") echo cid123 ;;
  "compose down"*) [ "${DOWN_FAIL:-0}" != 1 ] || exit 1 ;;
  "compose up"*)
    n=0; [ ! -f "${UP_COUNT:?}" ] || n=$(cat "$UP_COUNT")
    n=$((n + 1)); printf '%s' "$n" >"$UP_COUNT"
    [ "$n" -gt "${UP_FAILS:-0}" ] || exit 1
    ;;
esac
exit 0
EOF
cat >"$FB/bin/sudo" <<'EOF'
#!/usr/bin/env bash
if [ "$1" = chown ]; then [ "${CHOWN_FAIL:-0}" != 1 ]; exit; fi
exec "$@"
EOF
cat >"$FB/bin/systemctl" <<'EOF'
#!/usr/bin/env bash
echo "[systemctl] $*" >>"${DOCKER_LOG:-/dev/null}"
[ "${BOOT_FAIL:-0}" != 1 ]
EOF
cat >"$FB/bin/tar" <<'EOF'
#!/usr/bin/env bash
[ -z "${TAR_CALLED:-}" ] || : >"$TAR_CALLED"
[ "${TAR_FAIL:-1}" = 1 ] && exit 1
exec /usr/bin/tar "$@"
EOF
chmod +x "$FB/bin/docker" "$FB/bin/sudo" "$FB/bin/systemctl" "$FB/bin/tar"
cat >"$FB/.env" <<EOF
MONERO_ONION_ADDRESS=mona.onion
TARI_ONION_ADDRESS=taria.onion
P2POOL_ONION_ADDRESS=p2pa.onion
PROXY_AUTH_TOKEN=FBTOKEN
HOST_IP=box.lan
DEPLOYMENT_COMPLETED=true
COMPOSE_PROFILES=local_node
EOF
printf '{ "monero": {"mode":"local","wallet_address":"%s","node_username":"u","node_password":"p"}, "tari":{"wallet_address":"'"$VALID_TARI"'"}, "p2pool":{"pool":"main"}, "dashboard":{"secure":true,"host":"box.lan"} }\n' "$WALLET" >"$FB/config.json"

backup_case() {
    rm -f "$FB/docker.log" "$FB/up.count" "$FB/tar.called" "$FB"/backups/pithead-backup-*
    (cd "$FB" && DOCKER_LOG="$FB/docker.log" UP_COUNT="$FB/up.count" PATH="$FB/bin:$PATH" "$@" ./pithead backup -y --no-encrypt 2>&1)
}
out="$(backup_case env TAR_FAIL=1)"
rc=$?
assert_rc "failed plaintext backup exits non-zero" "$rc" 1
assert_contains "failed plaintext backup names the cause" "$out" "partial archive was removed"
assert_eq "failed plaintext backup leaves no archive" "$(ls "$FB"/backups/pithead-backup-* 2>/dev/null | head -1)" ""
assert_contains "failed plaintext backup restarts the stack" "$(cat "$FB/docker.log")" "compose up"

out="$(backup_case env DOWN_FAIL=1 TAR_CALLED="$FB/tar.called")"
assert_rc "a failed stop aborts backup and reports recovery" "$?" 1
assert_contains "failed stop keeps the original error context" "$out" "failed to stop"
assert_eq "failed stop attempts no archive" "$([ -e "$FB/tar.called" ] && echo yes || echo no)" no
assert_eq "failed stop recovers through one normal startup" "$(cat "$FB/up.count")" 1

out="$(backup_case env CHOWN_FAIL=1 TAR_FAIL=0)"
rc=$?
assert_rc "archive finalization failure is not success (#1965)" "$rc" 1
assert_contains "archive finalization failure names security" "$out" "could not be secured"
assert_eq "finalization failure recovers the stack" "$(cat "$FB/up.count")" 1
assert_eq "finalization failure retains the archive" "$(ls "$FB"/backups/pithead-backup-* 2>/dev/null | wc -l | tr -d ' ')" 1

out="$(backup_case env UP_FAILS=1 TAR_FAIL=0)"
rc=$?
assert_rc "backup retries one failed restart (#1965)" "$rc" 0
assert_contains "restart retry is reported" "$out" "retrying the normal startup path once"
assert_eq "restart retry makes two up attempts" "$(cat "$FB/up.count")" 2

out="$(backup_case env PITHEAD_APPLIANCE=1 UP_FAILS=99 TAR_FAIL=0)"
rc=$?
assert_rc "appliance backup recovers through the boot path (#1965)" "$rc" 0
assert_contains "appliance recovery starts the boot unit" "$(cat "$FB/docker.log")" "systemctl] restart pithead-boot.service"
assert_eq "appliance recovery does not repeat the failed compose path" "$(cat "$FB/up.count")" 1

out="$(backup_case env PITHEAD_APPLIANCE=1 UP_FAILS=99 BOOT_FAIL=1 TAR_FAIL=0)"
rc=$?
assert_rc "backup reports failed compose and boot-path recovery (#1965)" "$rc" 1
assert_contains "failed restart says the archive remains valid" "$out" "archive is valid"
assert_eq "valid archive survives restart failure" "$(ls "$FB"/backups/pithead-backup-* 2>/dev/null | wc -l | tr -d ' ')" 1
unset -f backup_case
