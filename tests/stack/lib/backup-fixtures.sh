# shellcheck shell=bash
# Shared archive fixture: backup and administrative restore build it in fresh processes.
build_backup_sandbox() {
    WALLET="${WALLET:-$VALID_PRIMARY}"
    # Stub docker/sudo while exercising a real archive round-trip for keys, dashboard DB, and Tor state.
    # The archive stores paths relative to '/', all confined to the sandbox (asserted below).
    # Use the sandbox's PHYSICAL path (pwd -P): `restore` extracts at '/', and on macOS the /var ->
    # /private/var symlink would otherwise make BSD tar refuse to "extract through symlink" (Linux /tmp
    # isn't symlinked, so this is a no-op there).
    BK="$(cd "$SANDBOX" && pwd -P)/backup"
    mkdir -p "$BK/build/tari" "$BK/data/tor" "$BK/data/dashboard" "$BK/bin"
    cp "$STACK" "$BK/pithead"
    cp "$ROOT/build/tari/config.toml.template" "$BK/build/tari/"
    cat >"$BK/bin/docker" <<'EOF'
#!/usr/bin/env bash
case "$*" in
  "compose ps --status running -q") exit 0 ;;   # empty output -> stack treated as not running
esac
exit 0
EOF
    cat >"$BK/bin/sudo" <<'EOF'
#!/usr/bin/env bash
# Run backup/restore's privileged commands as the test user, except chown (can't set 100:101
# unprivileged) which is accepted as a no-op so restore doesn't abort.
printf '%s\n' "$*" >>"${SUDO_LOG:-/dev/null}"
[ "$1" = "chown" ] && exit 0
if [ "$1" = cp ] && [ "$3" = --remove-destination ]; then cmd="$1" arg="$2"; shift 3; exec "$cmd" "$arg" "$@"; fi
exec "$@"
EOF
    chmod +x "$BK/bin/docker" "$BK/bin/sudo"
    cat >"$BK/.env" <<EOF
MONERO_ONION_ADDRESS=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa.onion
TARI_ONION_ADDRESS=bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb.onion
P2POOL_ONION_ADDRESS=cccccccccccccccccccccccccccccccccccccccccccccccccccccccc.onion
PROXY_AUTH_TOKEN=0123456789abcdef01234567
HOST_IP=box.lan
DEPLOYMENT_COMPLETED=true
COMPOSE_PROFILES=local_node
EOF
    printf '{ "monero": {"mode":"local","wallet_address":"%s","node_username":"u","node_password":"p"}, "tari":{"wallet_address":"'"$VALID_TARI"'"}, "p2pool":{"pool":"main"}, "dashboard":{"secure":true,"host":"box.lan"} }\n' "$WALLET" >"$BK/config.json"
    printf 'CADDY-ORIG\n' >"$BK/Caddyfile"
    printf 'ONIONKEY-ORIG\n' >"$BK/data/tor/hs_ed25519_secret_key"
    printf 'CircuitBuildAbandonedCount 1000\n' >"$BK/data/tor/state"
    printf 'DBDATA-ORIG\n' >"$BK/data/dashboard/dashboard.db"
}
