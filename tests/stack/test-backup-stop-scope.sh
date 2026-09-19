# shellcheck shell=bash
: "${STACK_SUITE:?is unset: this file is a tests/stack/run.sh fragment, not a script — run tests/stack/run.sh}"
# Sourced by run.sh: the backup window's stop scope (#2364). On the appliance, podman failed to
# unmount caddy's overlay ("directory not empty") when backup stopped it along with everything
# else via `compose down` — caddy is the container fronting the very dashboard request that
# triggers the backup, so tearing it down races that request. None of caddy's own state (its
# Caddyfile bind, its internal-CA data volume) is ever in the archive, so the fix leaves it
# running: assert the stop is a targeted `compose stop` that excludes caddy, never a full
# `compose down`.
echo "== unit: stack_backup — caddy stays up across the backup's own stop (#2364) =="
CD="$SANDBOX/backup-caddy-stays-up"
mkdir -p "$CD/build/tari" "$CD/data/tor" "$CD/data/dashboard" "$CD/bin"
cp "$STACK" "$CD/pithead"
cp "$ROOT/build/tari/config.toml.template" "$CD/build/tari/"
DOCKER_LOG="$CD/docker.log"
: >"$DOCKER_LOG"
cat >"$CD/bin/docker" <<EOF
#!/usr/bin/env bash
echo "\$*" >>"$DOCKER_LOG"
case "\$*" in
"compose ps --status running -q") echo fakecid ;;
"compose config --services") printf '%s\n' tor monerod tari p2pool dashboard caddy ;;
esac
exit 0
EOF
cat >"$CD/bin/sudo" <<'EOF'
#!/usr/bin/env bash
[ "$1" = "chown" ] && exit 0
exec "$@"
EOF
chmod +x "$CD/bin/docker" "$CD/bin/sudo"
cat >"$CD/.env" <<EOF
MONERO_ONION_ADDRESS=mona.onion
TARI_ONION_ADDRESS=taria.onion
P2POOL_ONION_ADDRESS=p2pa.onion
PROXY_AUTH_TOKEN=CDTOKEN
HOST_IP=box.lan
DEPLOYMENT_COMPLETED=true
COMPOSE_PROFILES=local_node
EOF
printf '{ "monero": {"mode":"local","wallet_address":"%s","node_username":"u","node_password":"p"}, "tari":{"wallet_address":"'"$VALID_TARI"'"}, "p2pool":{"pool":"main"}, "dashboard":{"secure":true,"host":"box.lan"} }\n' "$WALLET" >"$CD/config.json"
(cd "$CD" && PATH="$CD/bin:$PATH" ./pithead backup -y --no-encrypt) >/dev/null 2>&1
rc=$?
assert_rc "backup against a running stack exits 0" "$rc" "0"
stop_line="$(grep '^compose stop' "$DOCKER_LOG" | head -1)"
assert_contains "backup stops the stack via a targeted compose stop" "$stop_line" "compose stop"
case "$stop_line" in *caddy*) bad "caddy is excluded from the backup's stop" "$stop_line" ;; *) ok "caddy is excluded from the backup's stop" ;; esac
assert_not_contains "backup never runs a full compose down" "$(cat "$DOCKER_LOG")" "compose down"
unset CD DOCKER_LOG rc stop_line
