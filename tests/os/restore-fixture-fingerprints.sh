# shellcheck shell=bash
: "${OS_RUN_SUITE:?source via the suite runner}"

# Populate the source and N-1 archive fingerprints the KVM restore leg compares after boot.
restore_fixture_fingerprints() {
    local fixture_env fixture_config fixture_secrets
    RESTORE_SOURCE_ONION=$(_ssh "sed -n 's/^MONERO_ONION_ADDRESS=//p' /data/pithead/.env") || return 1
    RESTORE_SOURCE_SECRETS=$(_ssh "[ \$(grep -Ec '^(MONERO_NODE_(USERNAME|PASSWORD)|DASHBOARD_ONION_CLIENT_PRIVKEY)=' /data/pithead/.env) = 3 ] && grep -E '^(MONERO_NODE_(USERNAME|PASSWORD)|DASHBOARD_ONION_CLIENT_PRIVKEY)=' /data/pithead/.env | sha256sum | cut -d' ' -f1") || return 1
    RESTORE_SOURCE_AUTH_HASH=$(_ssh "sed -n 's/^DASHBOARD_AUTH_HASH_B64=//p' /data/pithead/.env") || return 1
    RESTORE_SOURCE_CONFIG=$(_ssh "jq -c '{monero: (.monero | {mode, wallet_address, node_username, node_password, remote}), tari: (.tari | {mode, wallet_address, remote}), p2pool: (.p2pool | {pool, stratum_password}), dashboard: (.dashboard | {auth, onion, control, energy})}' /data/pithead/config.json | sha256sum | cut -d' ' -f1") || return 1
    [ -n "$RESTORE_SOURCE_ONION" ] && [ -n "$RESTORE_SOURCE_SECRETS" ] && [ -n "$RESTORE_SOURCE_AUTH_HASH" ] && [ -n "$RESTORE_SOURCE_CONFIG" ] || return 1

    RESTORE_N1_DIR="$SCRIPT_DIR/fixtures/v1.20.0"
    [ -s "$RESTORE_N1_DIR/v1.20.0-backup.tar.gz.enc" ] && [ -s "$RESTORE_N1_DIR/passphrase" ] && [ -s "$RESTORE_N1_DIR/wallet" ] || return 1
    RESTORE_N1_ARCHIVE=$(mktemp)
    cp "$RESTORE_N1_DIR/v1.20.0-backup.tar.gz.enc" "$RESTORE_N1_ARCHIVE" || return 1
    fixture_env=$(openssl enc -d -aes-256-cbc -pbkdf2 -iter 600000 -pass "file:$RESTORE_N1_DIR/passphrase" \
        -in "$RESTORE_N1_ARCHIVE" 2>/dev/null | tar -xOzf - --wildcards '*/.env') || return 1
    fixture_config=$(openssl enc -d -aes-256-cbc -pbkdf2 -iter 600000 -pass "file:$RESTORE_N1_DIR/passphrase" \
        -in "$RESTORE_N1_ARCHIVE" 2>/dev/null | tar -xOzf - --wildcards '*/config.json') || return 1
    RESTORE_N1_WALLET=$(tr -d '\r\n' <"$RESTORE_N1_DIR/wallet")
    RESTORE_N1_ONION=$(printf '%s\n' "$fixture_env" | sed -n 's/^DASHBOARD_ONION_ADDRESS=//p')
    [ "$(printf '%s\n' "$fixture_env" | grep -Ec '^(MONERO_NODE_(USERNAME|PASSWORD)|DASHBOARD_ONION_CLIENT_PRIVKEY)=')" = 3 ] || return 1
    fixture_secrets=$(printf '%s\n' "$fixture_env" | grep -E '^(MONERO_NODE_(USERNAME|PASSWORD)|DASHBOARD_ONION_CLIENT_PRIVKEY)=') || return 1
    RESTORE_N1_SECRETS=$(printf '%s\n' "$fixture_secrets" | sha256sum | cut -d' ' -f1)
    RESTORE_N1_AUTH_HASH=$(printf '%s\n' "$fixture_env" | sed -n 's/^DASHBOARD_AUTH_HASH_B64=//p')
    RESTORE_N1_CONFIG=$(printf '%s\n' "$fixture_config" | jq -c '{monero: (.monero | {mode, wallet_address, node_username, node_password, remote}), tari: (.tari | {mode, wallet_address, remote}), p2pool: (.p2pool | {pool, stratum_password}), dashboard: (.dashboard | {auth, onion, control, energy})}' | sha256sum | cut -d' ' -f1)
    # The fixture must carry the removed 1.x keys, or the migration rows below prove nothing.
    printf '%s\n' "$fixture_config" | jq -e '(.xmrig_proxy | has("enabled") and has("url") and has("donor_id")) and (.telegram | has("control"))' >/dev/null || return 1
    RESTORE_N1_LEGACY=$(printf '%s\n' "$fixture_config" | jq -c "$RESTORE_LEGACY_JQ" | sha256sum | cut -d' ' -f1)
    RESTORE_N1_XVB_URL=$(printf '%s\n' "$fixture_config" | jq -r '.xmrig_proxy.url')
    RESTORE_N1_XVB_DONOR=$(printf '%s\n' "$fixture_config" | jq -r '.xmrig_proxy.donor_id')
    [ -n "$RESTORE_N1_WALLET" ] && [ -n "$RESTORE_N1_ONION" ] && [ -n "$RESTORE_N1_SECRETS" ] && [ -n "$RESTORE_N1_AUTH_HASH" ] && [ -n "$RESTORE_N1_CONFIG" ]
}

# The 1.x XvB settings 2.0.0 renamed (docs/configuration.md): xmrig_proxy.* -> xvb.*. Read off the
# v1.20.0 fixture as written and off the restored config.json under the new name, so both hash the
# same when the move is lossless.
readonly RESTORE_LEGACY_JQ='.xmrig_proxy | {enabled, url, donor_id}'
readonly RESTORE_MIGRATED_JQ='.xvb | {enabled, url, donor_id}'

restore_fixture_migration_verdict() {
    local migrated xvb_url xvb_donor
    _ssh "jq -e '(has(\"xmrig_proxy\") or ((.telegram // {}) | has(\"control\"))) | not' /data/pithead/config.json" >/dev/null &&
        ok "restore leg: the removed 1.x keys are gone from the restored config" ||
        bad "restore leg: the restored config still carries a removed 1.x key (xmrig_proxy or telegram.control)"
    migrated=$(_ssh "jq -c '$RESTORE_MIGRATED_JQ' /data/pithead/config.json | sha256sum | cut -d' ' -f1")
    [ "$migrated" = "$RESTORE_N1_LEGACY" ] &&
        ok "restore leg: v1.20.0 xmrig_proxy settings moved to xvb.* unchanged" ||
        bad "restore leg: v1.20.0 xmrig_proxy settings were lost or changed by the 1.x migration"
    # Restore migrates its staged copy and sweeps the staging dir (#1845): the archive is the
    # pre-migration copy, so no secret-bearing config.json.bak-1x may land on /data.
    _ssh "test ! -e /data/pithead/config.json.bak-1x" &&
        ok "restore leg: the restore left no config.json.bak-1x beside the migrated config" ||
        bad "restore leg: the restore left a config.json.bak-1x copy of the v1.20.0 config on /data"
    xvb_url=$(_ssh "sed -n 's/^XVB_POOL_URL=//p' /data/pithead/.env" | tr -d '\r')
    xvb_donor=$(_ssh "sed -n 's/^XVB_DONOR_ID=//p' /data/pithead/.env" | tr -d '\r')
    [ "$xvb_url" = "$RESTORE_N1_XVB_URL" ] && [ "$xvb_donor" = "$RESTORE_N1_XVB_DONOR" ] &&
        ok "restore leg: the rendered stack uses the migrated v1.20.0 XvB endpoint and donor id" ||
        bad "restore leg: the rendered XvB endpoint or donor id is not the migrated v1.20.0 value (got '${xvb_url:-none}', '${xvb_donor:-none}')"
}

restore_fixture_secret_verdict() {
    local restore_case=$1 expected_secrets=$2 expected_auth_hash
    local restored_secrets restored_auth_hash restored_auth_fp dashboard_user dashboard_password expected_auth_fp auth_code
    case "$restore_case" in
    same-version) expected_auth_hash=$RESTORE_SOURCE_AUTH_HASH ;;
    n1) expected_auth_hash=$RESTORE_N1_AUTH_HASH ;;
    esac
    restored_secrets=$(_ssh "[ \$(grep -Ec '^(MONERO_NODE_(USERNAME|PASSWORD)|DASHBOARD_ONION_CLIENT_PRIVKEY)=' /data/pithead/.env) = 3 ] && grep -E '^(MONERO_NODE_(USERNAME|PASSWORD)|DASHBOARD_ONION_CLIENT_PRIVKEY)=' /data/pithead/.env | sha256sum | cut -d' ' -f1")
    [ "$restored_secrets" = "$expected_secrets" ] &&
        ok "restore leg: restored RPC and onion-client secrets match the archive" ||
        bad "restore leg: restored RPC or onion-client secrets differ from the archive"
    restored_auth_hash=$(_ssh "sed -n 's/^DASHBOARD_AUTH_HASH_B64=//p' /data/pithead/.env")
    restored_auth_fp=$(_ssh "sed -n 's/^DASHBOARD_AUTH_PW_FP=//p' /data/pithead/.env")
    dashboard_user=$(_ssh "jq -r '.dashboard.auth.username // \"admin\"' /data/pithead/config.json")
    dashboard_password=$(_ssh "jq -r '.dashboard.auth.password // \"\"' /data/pithead/config.json")
    expected_auth_fp=$(printf '%s' "$dashboard_password" | sha256sum | cut -d' ' -f1)
    # shellcheck disable=SC2154  # shared through the assembled runner scope
    auth_code=$(curl -sSk -u "$dashboard_user:$dashboard_password" -m 10 -o /dev/null -w '%{http_code}' "https://$ip/api/state" 2>/dev/null || true)
    # Both archives carry a well-formed hash whose fingerprint matches their password, so restore
    # keeps that exact hash (#2579); a salted rehash would read as a changed credential.
    [ -n "$restored_auth_hash" ] && [ "$restored_auth_hash" = "$expected_auth_hash" ] &&
        ok "restore leg: dashboard bcrypt was restored exactly from the archive" ||
        bad "restore leg: dashboard bcrypt differs from the archive"
    [ -n "$dashboard_password" ] && [ "$restored_auth_fp" = "$expected_auth_fp" ] &&
        ok "restore leg: dashboard fingerprint matches the restored password" ||
        bad "restore leg: dashboard fingerprint does not match the restored password"
    [ "$auth_code" = 200 ] &&
        ok "restore leg: the restored dashboard password authenticates against the restored bcrypt" ||
        bad "restore leg: the restored dashboard password did not authenticate (got HTTP ${auth_code:-none})"
}
