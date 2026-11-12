# shellcheck shell=bash
: "${STACK_SUITE:?is unset: this file is a tests/stack/run.sh fragment, not a script — run tests/stack/run.sh}"

echo "== integration: stack_backup desired/applied data paths (#3877) =="
BDP="$(cd "$SANDBOX" && pwd -P)/backup-data-paths"
mkdir -p "$BDP/bin"
BDP_RESOLVER=$(sed -n '/^    # Resolve data directories/,/^    \[ "\$DASHBOARD_DIR" == "\$_dash_cfg" \] && DASHBOARD_DIR_IS_DEFAULT=0$/p' "$STACK")
assert_contains "data-path fixture extracted the production resolver" "$BDP_RESOLVER" 'DASHBOARD_DIR=$(resolve_default'

cat >"$BDP/bin/docker" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$BDP_DOCKER_LOG"
[ "$*" != "compose ps --status running -q" ] || [ "${BDP_RUNNING:-0}" != 1 ] || printf 'running\n'
EOF
cat >"$BDP/bin/sudo" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$BDP_SUDO_LOG"
[ "$1" != chown ] || exit 0
exec "$@"
EOF
cat >"$BDP/bin/flock" <<'EOF'
#!/usr/bin/env bash
if [ ! -e "$BDP_LOCK_MARK" ]; then
    : >"$BDP_LOCK_MARK"
    case "${BDP_LOCK_CHANGE:-}" in
    desired)
        jq --arg d "$BDP_NEW_DASH" '.dashboard.data_dir=$d' "$BDP_CONFIG" >"$BDP_CONFIG.next"
        mv "$BDP_CONFIG.next" "$BDP_CONFIG"
        ;;
    both)
        jq --arg d "$BDP_NEW_DASH" '.dashboard.data_dir=$d' "$BDP_CONFIG" >"$BDP_CONFIG.next"
        mv "$BDP_CONFIG.next" "$BDP_CONFIG"
        sed "s|^DASHBOARD_DATA_DIR=.*|DASHBOARD_DATA_DIR=$BDP_NEW_DASH|" "$BDP_ENV" >"$BDP_ENV.next"
        mv "$BDP_ENV.next" "$BDP_ENV"
        ;;
    esac
fi
[ -z "${BDP_REAL_FLOCK:-}" ] || exec "$BDP_REAL_FLOCK" "$@"
exit 0
EOF
chmod +x "$BDP/bin/docker" "$BDP/bin/sudo" "$BDP/bin/flock"

BDP_MONERO="$BDP/applied/monero"
BDP_TARI="$BDP/applied/tari"
BDP_P2POOL="$BDP/applied/p2pool"
BDP_TOR="$BDP/applied/tor"
BDP_DASH="$BDP/applied/dashboard"
BDP_NEW_DASH="$BDP/new/dashboard"

bdp_write_config() {
    jq -n \
        --arg monero "$BDP_MONERO" --arg tari "$BDP_TARI" --arg p2pool "$BDP_P2POOL" \
        --arg tor "$BDP_TOR" --arg dashboard "$BDP_DASH" \
        '{monero:{data_dir:$monero},tari:{data_dir:$tari},p2pool:{data_dir:$p2pool},tor:{data_dir:$tor},dashboard:{data_dir:$dashboard}}' \
        >"$BDP/config.json"
}

bdp_write_env() {
    printf '%s\n' \
        "MONERO_DATA_DIR=$BDP_MONERO" \
        "TARI_DATA_DIR=$BDP_TARI" \
        "P2POOL_DATA_DIR=$BDP_P2POOL" \
        "TOR_DATA_DIR=$BDP_TOR" \
        "DASHBOARD_DATA_DIR=$BDP_DASH" >"$BDP/.env"
}

bdp_reset() {
    rm -rf "$BDP/backups" "$BDP/applied" "$BDP/new" "$BDP/docker.log" "$BDP/sudo.log" "$BDP/lock.mark"
    mkdir -p "$BDP_MONERO" "$BDP_TARI" "$BDP_P2POOL" "$BDP_TOR" "$BDP_DASH"
    printf 'live-dashboard\n' >"$BDP_DASH/mining_data.db"
    bdp_write_config
    bdp_write_env
}

bdp_run() {
    local running="$1" change="$2"
    (
        cd "$BDP" || exit 1
        BDP_RUNNING="$running" BDP_LOCK_CHANGE="$change" BDP_NEW_DASH="$BDP_NEW_DASH" \
            BDP_CONFIG="$BDP/config.json" BDP_ENV="$BDP/.env" BDP_LOCK_MARK="$BDP/lock.mark" \
            BDP_DOCKER_LOG="$BDP/docker.log" BDP_SUDO_LOG="$BDP/sudo.log" \
            BDP_RESOLVER="$BDP_RESOLVER" BDP_REAL_FLOCK="$(command -v flock 2>/dev/null || true)" \
            PITHEAD_LOCK_FILE="$BDP/backup.lock" PATH="$BDP/bin:$PATH" \
            bash -Eeuo pipefail -c '
                source "$1"
                require_env() { :; }
                parse_and_validate_config() { eval "$BDP_RESOLVER"; }
                stack_down_except_caddy() { printf "stop\n" >>"$BDP_DOCKER_LOG"; }
                backup_restart_stack() { printf "restart\n" >>"$BDP_DOCKER_LOG"; }
                stack_backup -y --no-encrypt
            ' _ "$STACK"
    )
}

bdp_assert_metadata() {
    local archive="$1" label="$2" archived_config archived_env desired applied i
    archived_config=$(tar -xOzf "$archive" "${BDP#/}/config.json")
    archived_env=$(tar -xOzf "$archive" "${BDP#/}/.env")
    for i in "${!BDP_JSON_PATHS[@]}"; do
        desired=$(jq -r ".${BDP_JSON_PATHS[$i]}" <<<"$archived_config")
        applied=$(sed -n "s/^${BDP_ENV_KEYS[$i]}=//p" <<<"$archived_env")
        assert_eq "$label ${BDP_ENV_KEYS[$i]} metadata agrees" "$desired" "$applied"
    done
}

BDP_JSON_PATHS=(monero.data_dir tari.data_dir p2pool.data_dir tor.data_dir dashboard.data_dir)
BDP_ENV_KEYS=(MONERO_DATA_DIR TARI_DATA_DIR P2POOL_DATA_DIR TOR_DATA_DIR DASHBOARD_DATA_DIR)
for BDP_I in "${!BDP_JSON_PATHS[@]}"; do
    bdp_reset
    BDP_DESIRED="$BDP/desired/${BDP_ENV_KEYS[$BDP_I]}"
    jq --arg d "$BDP_DESIRED" ".${BDP_JSON_PATHS[$BDP_I]}=\$d" "$BDP/config.json" >"$BDP/config.next"
    mv "$BDP/config.next" "$BDP/config.json"
    BDP_OUT=$(bdp_run 1 "" 2>&1)
    BDP_RC=$?
    assert_rc "${BDP_ENV_KEYS[$BDP_I]} mismatch refuses backup" "$BDP_RC" 1
    assert_contains "${BDP_ENV_KEYS[$BDP_I]} refusal explains desired/applied inconsistency" "$BDP_OUT" "inconsistent data paths"
    assert_not_contains "${BDP_ENV_KEYS[$BDP_I]} refusal happens before service stop" "$(cat "$BDP/docker.log" 2>/dev/null)" "stop"
    assert_not_contains "${BDP_ENV_KEYS[$BDP_I]} refusal happens before tar" "$(cat "$BDP/sudo.log" 2>/dev/null)" "tar "
done

bdp_reset
BDP_OUT=$(bdp_run 0 "" 2>&1)
BDP_RC=$?
assert_rc "matching desired/applied paths create a stopped-stack backup" "$BDP_RC" 0
BDP_ARCHIVE=$(find "$BDP/backups" -type f -name 'pithead-backup-*.tar.gz' -print -quit 2>/dev/null)
BDP_LIST=$(tar -tzf "$BDP_ARCHIVE" 2>/dev/null)
assert_contains "matching control archives the live dashboard database" "$BDP_LIST" "${BDP_DASH#/}/mining_data.db"
assert_eq "matching control archives the live dashboard database bytes" \
    "$(tar -xOzf "$BDP_ARCHIVE" "${BDP_DASH#/}/mining_data.db")" "live-dashboard"
bdp_assert_metadata "$BDP_ARCHIVE" "matching control archived"

bdp_reset
BDP_OUT=$(bdp_run 1 desired 2>&1)
BDP_RC=$?
assert_rc "a data-path mismatch introduced at lock acquisition refuses backup" "$BDP_RC" 1
assert_eq "the mismatch was introduced at lock acquisition" "$([ -e "$BDP/lock.mark" ] && echo yes)" yes
assert_not_contains "the at-lock mismatch refuses before service stop" "$(cat "$BDP/docker.log" 2>/dev/null)" "stop"
assert_not_contains "the at-lock mismatch refuses before tar" "$(cat "$BDP/sudo.log" 2>/dev/null)" "tar "

bdp_reset
mkdir -p "$BDP_NEW_DASH"
printf 'new-live-dashboard\n' >"$BDP_NEW_DASH/mining_data.db"
BDP_OUT=$(bdp_run 0 both 2>&1)
BDP_RC=$?
assert_rc "matching desired/applied paths changed at lock still back up" "$BDP_RC" 0
BDP_ARCHIVE=$(find "$BDP/backups" -type f -name 'pithead-backup-*.tar.gz' -print -quit 2>/dev/null)
BDP_LIST=$(tar -tzf "$BDP_ARCHIVE" 2>/dev/null)
assert_contains "the lock-time rebuild archives the new live dashboard database" "$BDP_LIST" "${BDP_NEW_DASH#/}/mining_data.db"
assert_not_contains "the lock-time rebuild drops the stale dashboard selection" "$BDP_LIST" "${BDP_DASH#/}/mining_data.db"
assert_eq "the lock-time rebuild archives the new live database bytes" \
    "$(tar -xOzf "$BDP_ARCHIVE" "${BDP_NEW_DASH#/}/mining_data.db")" "new-live-dashboard"
bdp_assert_metadata "$BDP_ARCHIVE" "lock-time rebuilt archive"

unset BDP BDP_MONERO BDP_TARI BDP_P2POOL BDP_TOR BDP_DASH BDP_NEW_DASH BDP_I BDP_DESIRED
unset BDP_OUT BDP_RC BDP_ARCHIVE BDP_LIST BDP_RESOLVER
unset BDP_JSON_PATHS BDP_ENV_KEYS
unset -f bdp_write_config bdp_write_env bdp_reset bdp_run bdp_assert_metadata
