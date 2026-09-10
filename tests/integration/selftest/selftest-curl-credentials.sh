#!/usr/bin/env bash
# Exercise the shipped matrix probes with fake transports: secrets must reach curl
# stdin, never shell, SSH or curl argv. No server, credentials or Docker required.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=tests/integration/lib.sh
source "$HERE/../lib.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
mkdir "$TMP/bin" "$TMP/box"
REAL_BASH="$(command -v bash)"
export REAL_BASH ARGV_LOG="$TMP/argv" CURL_CONFIG="$TMP/config"
cat >"$TMP/bin/bash" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$@" >>"$ARGV_LOG"
exec "$REAL_BASH" "$@"
SH
# Avoid recursively resolving the wrapper's own interpreter through PATH.
sed "1s|.*|#!$REAL_BASH|" "$TMP/bin/bash" >"$TMP/bin/bash.fixed"
mv "$TMP/bin/bash.fixed" "$TMP/bin/bash"
cat >"$TMP/bin/ssh" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$@" >>"$ARGV_LOG"
for arg; do [ "$arg" != -n ] || exec </dev/null; done
exec "$REAL_BASH" -c "${!#}"
SH
cat >"$TMP/bin/curl" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$@" >>"$ARGV_LOG"
case " $* " in *' -K - '*) cat >"$CURL_CONFIG" ;; *) : >"$CURL_CONFIG" ;; esac
case "${!#}" in
*/get_info) printf '{"status":"OK","synchronized":true}\n' ;;
*/metrics) printf 'pithead_up 1\n' ;;
*/apply | */status) printf '{"change_id":"fixture-change","status":"applied"}\n' ;;
*) exit 97 ;;
esac
SH
chmod +x "$TMP/bin/"*
export PATH="$TMP/bin:$PATH"
export IT_MODE IT_REMOTE_DIR="$TMP/box" IT_SSH_DEST=fixture.invalid
IT_DASHBOARD_PASSWORD='fixturesecret42"\tail'
IT_RIG_TOKEN='fixturesecret42"\token'
export RIG_HOST=worker.invalid RIG_CONTROL_PORT=8082
printf 'MONERO_NODE_USERNAME=fixture-user\nMONERO_NODE_PASSWORD=%s\n' "$IT_DASHBOARD_PASSWORD" >"$TMP/box/.env"
printf '{"monero":{"mode":"local"}}\n' >"$TMP/box/config.json"

# These functions have no direct entry point; extract the actual shipped bodies.
for spec in \
    "assert_metrics_via_caddy:$HERE/../lib/run-scenario.sh" \
    "_rig_control_apply:$HERE/../lib/run-rig-reverse.sh" \
    "_rig_control_await:$HERE/../lib/run-rig-reverse.sh"; do
    name=${spec%%:*}
    body="$(sed -n "/^$name() {/,/^}/p" "${spec#*:}")"
    test -n "$body"
    eval "$body"
done
# The restore probe is sent as a literal stdin script by verify_restore_proof.
sed -n "/^u=\$(grep -E '\^MONERO_NODE_USERNAME='/,/^PROBE$/p" "$HERE/../lib/restore-proof.sh" |
    sed '$d' >"$TMP/restore-probe"
test -s "$TMP/restore-probe"

env_on_box() {
    case "$1" in
    HOST_IP) printf dashboard.invalid ;;
    DASHBOARD_SECURE) printf false ;;
    HOST_PORT) printf 80 ;;
    DASHBOARD_AUTH_HASH_B64) printf configured ;;
    DASHBOARD_AUTH_USER) printf fixture-user ;;
    *) return 1 ;;
    esac
}
check_transport() { # <config directive> <expected decoded credential>
    if grep -Fq fixturesecret42 "$ARGV_LOG"; then
        echo 'FAIL: fixture credential entered process argv' >&2
        return 1
    fi
    test "$(sed "s/^$1 = //" "$CURL_CONFIG" | jq -r .)" = "$2"
}

echo "== authenticated probes keep credentials in curl config stdin and ordinary SSH stdin untouched =="
for IT_MODE in local ssh; do
    : >"$ARGV_LOG"
    monero_caught_up
    check_transport user "fixture-user:$IT_DASHBOARD_PASSWORD"
    assert_metrics_via_caddy
    check_transport user "fixture-user:$IT_DASHBOARD_PASSWORD"
    test "$(_rig_control_apply '{"max_temp_c":75}')" = fixture-change
    check_transport header "Authorization: Bearer $IT_RIG_TOKEN"
    _rig_control_await fixture-change applied 1
    check_transport header "Authorization: Bearer $IT_RIG_TOKEN"
    # Same static command and stdin script that the restore's on_bench transports.
    test "$(rx 'bash -s' --stdin <"$TMP/restore-probe")" = rpc-ok
    check_transport user "fixture-user:$IT_DASHBOARD_PASSWORD"
done
# Ordinary SSH commands must still leave scenario-loop input unread.
test -z "$(printf 'fixture loop input\n' | rx cat)"
test "$(printf 'fixture pipe input\n' | rx cat --stdin)" = 'fixture pipe input'
test "$IT_FAIL" -eq 0
printf 'curl credential transport: 10 local/SSH probes and 2 stdin controls passed\n'
