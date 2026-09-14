# shellcheck shell=bash
: "${OS_RUN_SUITE:?source via the suite runner}"

# Populate the source and N-1 archive fingerprints the KVM restore leg compares after boot.
restore_fixture_fingerprints() {
    local fixture_env fixture_config fixture_secrets
    RESTORE_SOURCE_ONION=$(_ssh "sed -n 's/^DASHBOARD_ONION_ADDRESS=//p' /data/pithead/.env") || return 1
    RESTORE_SOURCE_SECRETS=$(_ssh "grep -Eq '^(MONERO_NODE_(USERNAME|PASSWORD)|DASHBOARD_AUTH_HASH_B64|DASHBOARD_ONION_CLIENT_PRIVKEY)=' /data/pithead/.env && grep -E '^(MONERO_NODE_(USERNAME|PASSWORD)|DASHBOARD_AUTH_HASH_B64|DASHBOARD_ONION_CLIENT_PRIVKEY)=' /data/pithead/.env | sha256sum | cut -d' ' -f1") || return 1
    RESTORE_SOURCE_CONFIG=$(_ssh "jq -c '{monero: {mode, wallet_address, node_username, node_password, remote}, tari: {mode, wallet_address, remote}, p2pool: {pool, stratum_password}, dashboard: {auth, onion, control, energy}}' /data/pithead/config.json | sha256sum | cut -d' ' -f1") || return 1
    [ -n "$RESTORE_SOURCE_ONION" ] && [ -n "$RESTORE_SOURCE_SECRETS" ] && [ -n "$RESTORE_SOURCE_CONFIG" ] || return 1

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
    fixture_secrets=$(printf '%s\n' "$fixture_env" | grep -E '^(MONERO_NODE_(USERNAME|PASSWORD)|DASHBOARD_AUTH_HASH_B64|DASHBOARD_ONION_CLIENT_PRIVKEY)=') || return 1
    RESTORE_N1_SECRETS=$(printf '%s\n' "$fixture_secrets" | sha256sum | cut -d' ' -f1)
    RESTORE_N1_CONFIG=$(printf '%s\n' "$fixture_config" | jq -c '{monero: {mode, wallet_address, node_username, node_password, remote}, tari: {mode, wallet_address, remote}, p2pool: {pool, stratum_password}, dashboard: {auth, onion, control, energy}}' | sha256sum | cut -d' ' -f1)
    [ -n "$RESTORE_N1_WALLET" ] && [ -n "$RESTORE_N1_ONION" ] && [ -n "$RESTORE_N1_SECRETS" ] && [ -n "$RESTORE_N1_CONFIG" ]
}
