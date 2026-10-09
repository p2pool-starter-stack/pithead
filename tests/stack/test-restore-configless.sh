# shellcheck shell=bash
: "${STACK_SUITE:?source via tests/stack/run.sh}"
echo "== recovery: missing rendered configuration =="
build_backup_sandbox
RCF="$SANDBOX/configless-restore"
mkdir -p "$RCF"
# Real encrypted archive with a custom dashboard path, trusted only via the live deployment.
mkdir -p "$BK/custom/dashboard"
mv "$BK/data/dashboard/dashboard.db" "$BK/custom/dashboard/"
jq --arg path "$BK/custom/dashboard" '.dashboard.data_dir=$path' "$BK/config.json" >"$BK/config.tmp"
mv "$BK/config.tmp" "$BK/config.json"
printf 'DASHBOARD_DATA_DIR=%s\n' "$BK/custom/dashboard" >>"$BK/.env"
(cd "$BK" && PITHEAD_BACKUP_PASSPHRASE='reset recovery fixture' PATH="$BK/bin:$PATH" ./pithead backup -y) >"$RCF/backup.log" 2>&1
assert_rc "configless fixture creates a real encrypted backup" "$?" 0
RCF_ARCHIVE=$(find "$BK/backups" -name '*.enc' -print -quit)
cat >"$BK/bin/docker" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"${DOCKER_LOG:?}"
case "$1" in
compose) [ -f .env ] || { echo 'PROXY_API_PORT is empty' >&2; exit 1; } ;;
ps)
    [ "${ENGINE_FAIL:-0}" != 1 ] || exit 1
    n=0
    if [ -n "${PS_COUNT:-}" ]; then
        [ ! -e "$PS_COUNT" ] || n=$(cat "$PS_COUNT")
        n=$((n + 1)); printf '%s' "$n" >"$PS_COUNT"
    fi
    case "$*" in
    *label=com.docker.compose.project=pithead*)
        case "$*" in
        *status=*)
            if [ -z "${ACTIVE_AFTER:-}" ] || [ "$n" -gt "$ACTIVE_AFTER" ]; then
                [[ "$*" != *"status=${STACK_STATUS:-absent}"* ]] || printf 'fixture-id\n'
            fi ;;

        *) [ ! -f "${ACTIVE_FILE:-/dev/null}" ] || printf 'fixture-id\n' ;;
        esac ;;
    esac ;;
unpause) [ "${UNPAUSE_FAIL:-0}" != 1 ] || exit 1 ;;
stop) [ "${STOP_FAIL:-0}" != 1 ] || exit 1 ;;
rm) rm -f "${ACTIVE_FILE:-/dev/null}" ;;
esac
exit 0
EOF
chmod +x "$BK/bin/docker"
export DOCKER_LOG="$RCF/docker.log"
: >"$DOCKER_LOG"
mkdir "$BK/.restore-paths"
out=$(cd "$BK" && PITHEAD_APPLIANCE=0 PATH="$BK/bin:$PATH" ./pithead config-reset -y 2>&1)
assert_rc "failed destination preservation prevents reset" "$?" 1
assert_eq "failed preservation leaves live configuration intact" "$(test -e "$BK/config.json" && test -e "$BK/.env" && echo intact)" intact
rmdir "$BK/.restore-paths"
out=$(cd "$BK" && PITHEAD_APPLIANCE=0 PATH="$BK/bin:$PATH" ./pithead config-reset -y 2>&1)
assert_rc "reset preserves destination context before clearing rendered files" "$?" 0
assert_eq "reset removes all three configuration files" "$(find "$BK" -maxdepth 1 \( -name config.json -o -name .env -o -name Caddyfile \) -print)" ""
assert_eq "reset destination context is owner-only" "$(file_mode "$BK/.restore-paths")" 600
assert_contains "reset destination context retains custom data directory" "$(cat "$BK/.restore-paths")" "$BK/custom/dashboard"
assert_not_contains "reset destination context contains no generated secrets" "$(cat "$BK/.restore-paths")" PROXY_AUTH_TOKEN
: >"$DOCKER_LOG"
for rcf_status in running restarting paused; do
    out=$(cd "$BK" && STACK_STATUS="$rcf_status" PATH="$BK/bin:$PATH" ./pithead restore -y "$RCF_ARCHIVE" 2>&1)
    assert_rc "restore refuses $rcf_status containers without env" "$?" 1
    assert_contains "configless $rcf_status refusal names actual precondition" "$out" "stack services are still active"
    assert_not_contains "configless $rcf_status refusal does not blame Docker" "$out" "Fix Docker access"
    assert_eq "refused restore leaves configuration absent" "$(test -e "$BK/config.json" && echo present)" ""
done
out=$(cd "$BK" && ENGINE_FAIL=1 PATH="$BK/bin:$PATH" ./pithead restore -y "$RCF_ARCHIVE" 2>&1)
assert_rc "configless Docker census failure refuses restore" "$?" 1
assert_contains "engine failure still names Docker access" "$out" "Fix Docker access"
out=$(cd "$BK" && PATH="$BK/bin:$PATH" ./pithead restore -y "$RCF_ARCHIVE" </dev/null 2>&1)
assert_rc "stopped configless restore reaches passphrase request" "$?" 1
assert_contains "stopped configless restore names missing passphrase" "$out" "This archive is encrypted"
assert_not_contains "recovery does not interpolate Compose without env" "$(grep '^compose ' "$DOCKER_LOG" || true)" 'compose '

: >"$RCF/active"
: >"$DOCKER_LOG"
out=$(cd "$BK" && ACTIVE_FILE="$RCF/active" STOP_FAIL=1 PATH="$BK/bin:$PATH" ./pithead down 2>&1)
assert_rc "failed configless stop fails down" "$?" 1
assert_not_contains "failed stop never removes containers" "$(cat "$DOCKER_LOG")" 'rm fixture-id'
: >"$DOCKER_LOG"
out=$(cd "$BK" && ACTIVE_FILE="$RCF/active" PATH="$BK/bin:$PATH" ./pithead down 2>&1)
assert_rc "down stops containers with no env" "$?" 0
assert_contains "configless down stops only selected container IDs" "$(cat "$DOCKER_LOG")" 'stop fixture-id'
assert_contains "configless down removes selected containers without volumes" "$(cat "$DOCKER_LOG")" 'rm fixture-id'
assert_not_contains "configless down never interpolates Compose" "$(grep '^compose ' "$DOCKER_LOG" || true)" 'compose '
assert_contains "legacy selection requires this working directory" "$(cat "$DOCKER_LOG")" "label=com.docker.compose.project.working_dir=$BK"

out=$(cd "$BK" && PS_COUNT="$RCF/ps-count" ACTIVE_AFTER=6 STACK_STATUS=running PITHEAD_BACKUP_PASSPHRASE='reset recovery fixture' PATH="$BK/bin:$PATH" ./pithead restore -y "$RCF_ARCHIVE" 2>&1)
assert_rc "configless restore rechecks active services under the mutation lock" "$?" 1
assert_contains "late configless startup gives the active-stack refusal" "$out" "stack services are still active"
assert_eq "late configless startup prevents config promotion" "$(test -e "$BK/config.json" && echo present)" ""
: >"$RCF/active"
: >"$DOCKER_LOG"
out=$(cd "$BK" && ACTIVE_FILE="$RCF/active" STACK_STATUS=paused UNPAUSE_FAIL=1 PATH="$BK/bin:$PATH" ./pithead down 2>&1)
assert_rc "failed unpause refuses configless shutdown" "$?" 1
assert_not_contains "failed unpause never removes containers" "$(cat "$DOCKER_LOG")" 'rm fixture-id'
: >"$DOCKER_LOG"
out=$(cd "$BK" && ACTIVE_FILE="$RCF/active" STACK_STATUS=paused PATH="$BK/bin:$PATH" ./pithead down 2>&1)
assert_rc "configless down gracefully stops paused containers" "$?" 0
assert_contains "paused shutdown unpauses before stopping" "$(cat "$DOCKER_LOG")" 'unpause fixture-id'

# Malformed, moved, and redirected trust records fail closed, not an archive-derived allowlist.
cp "$BK/.restore-paths" "$RCF/paths"
chmod 666 "$BK/.restore-paths"
out=$(cd "$BK" && PATH="$BK/bin:$PATH" run_sourced_e "$BK" restore_collect_destinations 2>&1)
assert_rc "writable local destination record refuses" "$?" 1
chmod 644 "$BK/.restore-paths"
out=$(cd "$BK" && PATH="$BK/bin:$PATH" run_sourced_e "$BK" restore_collect_destinations 2>&1)
assert_rc "publicly readable local destination record refuses" "$?" 1
chmod 600 "$BK/.restore-paths"
out=$(cd "$BK" && PATH="$BK/bin:$PATH" run_sourced_e "$BK" eval 'stat() { if [ "$2" = %u ]; then printf 999999; else command stat "$@"; fi; }; restore_collect_destinations' 2>&1)
assert_rc "destination record owned by another user refuses" "$?" 1
out=$(cd "$BK" && run_sourced_e "$BK" eval 'RESTORE_ALLOWED_DIRS=("$PWD"); restore_member_allowed "${PWD#/}/.restore-paths"' 2>&1)
assert_rc "archive cannot supply reset policy inside an overlapping data directory" "$?" 1
out=$(cd "$BK" && run_sourced_e "$BK" eval 'RESTORE_ALLOWED_DIRS=("$PWD"); restore_member_allowed "${PWD#/}/.restore-paths/injected"' 2>&1)
assert_rc "archive cannot create a directory at the reset policy path" "$?" 1
printf '{}' >"$BK/.restore-paths"
out=$(cd "$BK" && PATH="$BK/bin:$PATH" run_sourced_e "$BK" restore_collect_destinations 2>&1)
assert_rc "invalid local destination record refuses" "$?" 1
jq '.install="/srv/other-install"' "$RCF/paths" >"$BK/.restore-paths"
out=$(cd "$BK" && PATH="$BK/bin:$PATH" run_sourced_e "$BK" restore_collect_destinations 2>&1)
assert_rc "destination record from another install refuses" "$?" 1
rm "$BK/.restore-paths"
ln -s "$RCF/paths" "$BK/.restore-paths"
out=$(cd "$BK" && PATH="$BK/bin:$PATH" run_sourced_e "$BK" restore_collect_destinations 2>&1)
assert_rc "symlinked destination record refuses" "$?" 1
rm "$BK/.restore-paths"
cp "$RCF/paths" "$BK/.restore-paths"
chmod 600 "$BK/.restore-paths"
out=$(cd "$BK" && PITHEAD_BACKUP_PASSPHRASE='reset recovery fixture' PATH="$BK/bin:$PATH" ./pithead restore -y "$RCF_ARCHIVE" 2>&1)
assert_rc "encrypted restore after reset succeeds with no manual env" "$?" 0
assert_eq "custom dashboard data restores" "$(cat "$BK/custom/dashboard/dashboard.db")" DBDATA-ORIG
assert_contains "restore renders the retained custom destination" "$(cat "$BK/.env")" "DASHBOARD_DATA_DIR=$BK/custom/dashboard"
assert_eq "successful restore retires reset destination context" "$(test -e "$BK/.restore-paths" && echo present)" ""
# A fresh default install needs no trust record; an archive still cannot authorize custom paths.
rm -f "$BK/.env" "$BK/config.json" "$BK/Caddyfile"
out=$(cd "$BK" && PITHEAD_BACKUP_PASSPHRASE='reset recovery fixture' PATH="$BK/bin:$PATH" ./pithead restore -y "$RCF_ARCHIVE" 2>&1)
assert_rc "custom archive without trusted destination context refuses" "$?" 1
assert_contains "custom archive refusal gives destination prerequisite" "$out" "Configure the destination first"
build_backup_sandbox
rm -f "$BK"/backups/*.enc
(cd "$BK" && PITHEAD_BACKUP_PASSPHRASE='reset recovery fixture' PATH="$BK/bin:$PATH" ./pithead backup -y) >"$RCF/default-backup.log" 2>&1
assert_rc "default recovery fixture creates an encrypted backup" "$?" 0
RCF_DEFAULT=$(find "$BK/backups" -name '*.enc' -print -quit)
rm -f "$BK/config.json" "$BK/.env" "$BK/Caddyfile"
out=$(cd "$BK" && PITHEAD_BACKUP_PASSPHRASE='reset recovery fixture' PATH="$BK/bin:$PATH" ./pithead restore -y "$RCF_DEFAULT" 2>&1)
assert_rc "fresh default-path restore needs no configuration or reset record" "$?" 0
assert_eq "fresh default restore preserves dashboard data" "$(cat "$BK/data/dashboard/dashboard.db")" DBDATA-ORIG
unset DOCKER_LOG RCF RCF_ARCHIVE RCF_DEFAULT rcf_status out
