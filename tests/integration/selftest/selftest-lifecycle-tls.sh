#!/usr/bin/env bash
set -euo pipefail
echo "== lifecycle TLS certificate continuity =="
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
# shellcheck source=tests/integration/lib/run-lifecycle-tls.sh
source "$ROOT/tests/integration/lib/run-lifecycle-tls.sh"
work=$(mktemp -d "${TMPDIR:?}/pithead-lifecycle-tls.XXXXXX")
trap 'rm -rf "$work"' EXIT
fail() {
    printf 'FAIL: %s\n' "$1" >&2
    exit 1
}
openssl req -x509 -newkey rsa:2048 -nodes -days 1 -keyout "$work/key" -out "$work/cert" \
    -subj /CN=fixture.invalid -addext 'subjectAltName=DNS:fixture.invalid,IP:192.0.2.20' >/dev/null 2>&1
env_on_box() { case "$1" in HOST_IP) printf fixture.invalid ;; HOST_PORT) printf 443 ;; DASHBOARD_SECURE) printf '%s' "${fixture_secure:-true}" ;; esac }
quote_arg() { printf "'%s'" "$1"; }
rx() {
    case "$1" in
    *'openssl s_client'*) cat "$work/cert" ;;
    *'docker exec caddy'*) openssl dgst -sha256 "$work/key" ;;
    'cat config.json') printf '{"dashboard":{"auth":{"password":"original"}}}' ;;
    *) return 1 ;;
    esac
}
identity=$(dashboard_tls_identity)
[ -n "$identity" ] || fail 'real certificate snapshot was empty'
case "$identity" in *DNS:fixture.invalid*IPAddress:192.0.2.20*) ;; *) fail 'snapshot omitted canonical SANs' ;; esac
IT_FAIL=0
IT_PASS=0
it_pass() { IT_PASS=$((IT_PASS + 1)); }
it_fail() { IT_FAIL=$((IT_FAIL + 1)); }
dashboard_tls_identity() { printf '%s' "$fixture_identity"; }
fixture_identity=$identity
assert_dashboard_tls_continuity restore "$identity" || fail 'unchanged leaf/key failed'
[ "$IT_PASS" = 1 ] && [ "$IT_FAIL" = 0 ] || fail 'unchanged identity was not counted'
fixture_identity="$identity-changed-key"
if assert_dashboard_tls_continuity restore "$identity"; then fail 'key change passed'; fi
if assert_dashboard_tls_continuity restore ''; then fail 'missing pre-operation identity passed'; fi
push_config() { printf '%s\n' "$1" | jq -c . >>"$work/configs"; }
pithead() {
    [ "$1:$2" = apply:-y ] || return 1
    [ "${fixture_apply_fails:-0}" = 0 ]
}
wait_status_ok() { return 0; }
fixture_identity=$identity
run_password_tls_continuity || fail 'password apply round-trip failed'
[ "$(wc -l <"$work/configs" | tr -d ' ')" = 2 ] || fail 'password fixture omitted cleanup'
[ "$(tail -n1 "$work/configs" | jq -r '.dashboard.auth.password')" = original ] || fail 'password was not restored'
fixture_apply_fails=1
if run_password_tls_continuity; then fail 'failed apply passed'; fi
[ "$(wc -l <"$work/configs" | tr -d ' ')" = 4 ] || fail 'failed password apply omitted cleanup attempt'
fixture_secure=false
IT_SKIP=0
it_skip_leg() { IT_SKIP=$((IT_SKIP + 1)); }
assert_dashboard_tls_continuity restore http-only
run_password_tls_continuity
[ "$IT_SKIP" = 2 ] || fail 'HTTP-only configuration was not explicitly counted'
printf 'Lifecycle TLS self-test: PASS\n'
