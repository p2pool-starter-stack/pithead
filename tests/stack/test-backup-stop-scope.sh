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
case "$stop_line" in
"") bad "caddy is excluded from the backup's stop" "no 'compose stop' line was captured at all" ;;
*caddy*) bad "caddy is excluded from the backup's stop" "$stop_line" ;;
*) ok "caddy is excluded from the backup's stop" ;;
esac
assert_not_contains "backup never runs a full compose down" "$(cat "$DOCKER_LOG")" "compose down"
unset CD DOCKER_LOG rc stop_line

# The caddy filter can legitimately match everything (a compose file whose only service is caddy,
# or a `config --services` that fails and prints nothing). That must reach the guard and abort with
# its message. Assigning `config --services | grep -vxF caddy` as one pipeline does not: under the
# CLI's `set -Eeuo pipefail` a grep matching nothing fails the assignment and errexit takes the
# shell out before the guard can run (the #2059 trap, documented in 02-tor-egress.sh). stack_backup
# happens to call this inside `if ! ( ... )`, which suspends errexit and hides the trap, so the
# function is exercised directly here — the way any future caller would reach it.
echo "== unit: stack_down_except_caddy — a caddy-only service list reaches the guard (#2364) =="
CD="$SANDBOX/backup-caddy-only-list"
mkdir -p "$CD/bin"
cp "$STACK" "$CD/pithead"
DOCKER_LOG="$CD/docker.log"
: >"$DOCKER_LOG"
cat >"$CD/bin/docker" <<EOF
#!/usr/bin/env bash
echo "\$*" >>"$DOCKER_LOG"
case "\$*" in
"compose config --services") printf '%s\n' caddy ;;
esac
exit 0
EOF
cat >"$CD/bin/sudo" <<'EOF'
#!/usr/bin/env bash
exec "$@"
EOF
printf '#!/usr/bin/env bash\nexit 0\n' >"$CD/bin/nft"
chmod +x "$CD/bin/docker" "$CD/bin/sudo" "$CD/bin/nft"
out="$( (cd "$CD" && PATH="$CD/bin:$PATH" bash -c 'set -Eeuo pipefail; source ./pithead; stack_down_except_caddy') 2>&1)"
rc=$?
if [ "$rc" != "0" ]; then ok "a caddy-only service list fails the stop"; else bad "a caddy-only service list fails the stop" "expected a non-zero rc, got 0"; fi
assert_contains "the empty filtered list reaches the guard's message" "$out" "Could not list compose services to stop for the backup."
assert_not_contains "no unargumented compose stop (it would stop caddy too)" "$(cat "$DOCKER_LOG")" "compose stop"
unset CD DOCKER_LOG rc out
