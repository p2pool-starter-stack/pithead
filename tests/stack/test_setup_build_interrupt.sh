#!/usr/bin/env bash
set -uo pipefail
interrupt_cli="${1:-}"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=tests/stack/lib.sh
source "$HERE/lib.sh"
echo "== unit: source setup build interruption and retry =="
build_val_sandbox
[ -z "$interrupt_cli" ] || cp "$interrupt_cli" "$V/pithead"
mv "$V/bin/docker" "$V/bin/docker.base"
cat >"$V/bin/docker" <<'STUB'
#!/usr/bin/env bash
case "$*" in
    compose*' up '*' tor')
        if [ ! -f "$INTERRUPT_MARKER" ]; then
            touch "$INTERRUPT_MARKER"
            printf '%s\n' 'failed to solve: failed to stat active key during commit: snapshot does not exist: not found' >&2
            kill -INT "$$"
            exit 99
        fi
        ;;
esac
exec "$(dirname "$0")/docker.base" "$@"
STUB
chmod +x "$V/bin/docker"
mv "$V/bin/sudo" "$V/bin/sudo.base"
cat >"$V/bin/sudo" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$SUDO_LOG"
exec "$(dirname "$0")/sudo.base" "$@"
STUB
chmod +x "$V/bin/sudo"
cp "$ROOT/VERSION" "$V/VERSION"
fixture_version=$(sed 's/[-+].*//' "$V/VERSION" | tr -d ' \t\r\n')
printf '{"config_version":"%s","monero":{"mode":"local","wallet_address":"%s","node_username":"fixture","node_password":"fixture"},"tari":{"mode":"off"},"p2pool":{"pool":"mini"},"dashboard":{"secure":false}}\n' "$fixture_version" "$VALID_PRIMARY" >"$V/config.json"
chmod 600 "$V/config.json"
cp "$V/config.json" "$V/config.before"
export INTERRUPT_MARKER="$V/interrupted" DOCKER_LOG="$V/docker.log" SUDO_LOG="$V/sudo.log"
: >"$DOCKER_LOG"
: >"$SUDO_LOG"
for tool in systemctl service; do
    cat >"$V/bin/$tool" <<'STUB'
#!/usr/bin/env bash
printf '%s %s\n' "$(basename "$0")" "$*" >>"$SUDO_LOG"
STUB
    chmod +x "$V/bin/$tool"
done
interrupt_out=$(cd "$V" && PATH="$V/bin:$PATH" bash ./pithead setup --skip-deps --skip-optimize </dev/null 2>&1)
interrupt_rc=$?
assert_eq "Tor build interruption reaches the injected SIGINT" "$([ -f "$INTERRUPT_MARKER" ] && echo yes)" yes
assert_rc "Tor build interruption preserves exit 130" "$interrupt_rc" 130
assert_contains "Tor build interruption names the BuildKit failure" "$interrupt_out" 'failed to stat active key'
assert_contains "Tor build interruption identifies setup's failed phase" "$interrupt_out" 'Tor image build or startup failed (exit 130)'
assert_eq "Tor build interruption retains configuration bytes" "$(cmp -s "$V/config.before" "$V/config.json" && echo yes)" yes
assert_eq "Tor build interruption retains owner-only configuration" "$(file_mode "$V/config.json")" 600
assert_not_contains "Tor build interruption never claims provisioning completed" "$interrupt_out" 'Deployment preparation complete!'
retry_out=$(cd "$V" && printf '\nn\n' | PATH="$V/bin:$PATH" bash ./pithead setup --skip-deps --skip-optimize 2>&1)
retry_rc=$?
assert_rc "Tor build retry provisions successfully" "$retry_rc" 0
assert_contains "Tor build retry reports completed preparation" "$retry_out" 'Deployment preparation complete!'
assert_contains "Tor build retry records deployment completion" "$(cat "$V/.env")" 'DEPLOYMENT_COMPLETED=true'
assert_eq "Tor build retry retains configuration bytes" "$(cmp -s "$V/config.before" "$V/config.json" && echo yes)" yes
assert_eq "Tor build retry retains owner-only configuration" "$(file_mode "$V/config.json")" 600
if grep -Eq ' (restart|prune|rm)( |$)' "$DOCKER_LOG" ||
    grep -Eq '(systemctl (restart|stop)|service docker (restart|stop))' "$SUDO_LOG"; then
    bad "Tor build recovery never restarts Docker or deletes containers/cache" 'destructive Docker call'
else
    ok "Tor build recovery never restarts Docker or deletes containers/cache"
fi
printf 'setup build interruption: %s passed, %s failed\n' "$PASS" "$FAIL"
[ "$PASS" -gt 0 ] && [ "$FAIL" -eq 0 ]
