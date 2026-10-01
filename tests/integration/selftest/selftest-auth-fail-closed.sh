#!/usr/bin/env bash
# Credential replacement and failed-restore diagnostics, without a live stack.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=tests/integration/lib.sh
source "$HERE/../lib.sh"
export INTEGRATION_RUN_SUITE=1
# shellcheck source=tests/integration/lib/run-hardening.sh
source "$HERE/../lib/run-hardening.sh"
TD="$(mktemp -d)"
trap 'rm -rf "$TD"' EXIT
export IT_MODE=local IT_REMOTE_DIR="$TD"
mkdir "$TD/bin"
AUTH_TEST_AWK="$(command -v awk)"
AUTH_TEST_CHOWN="$(command -v chown)"
AUTH_TEST_MV="$(command -v mv)"
export AUTH_TEST_AWK AUTH_TEST_CHOWN AUTH_TEST_MV AUTH_TEST_DIR="$TD"
cat >"$TD/bin/awk" <<'SH'
#!/usr/bin/env bash
# Observe the secret-bearing temporary file while the real writer holds it open.
for f in .env.itest*; do
    [ -f "$f" ] || continue
    stat -c %a "$f" >>"$AUTH_TEST_DIR/modes"
done
[ "${AUTH_TEST_FAIL:-}" != awk ] || exit 1
exec "$AUTH_TEST_AWK" "$@"
SH
for tool in chown mv; do
    cat >"$TD/bin/$tool" <<'SH'
#!/usr/bin/env bash
tool=${0##*/}
[ "${AUTH_TEST_FAIL:-}" != "$tool" ] || exit 1
case "$tool" in
chown) exec "$AUTH_TEST_CHOWN" "$@" ;;
mv) exec "$AUTH_TEST_MV" "$@" ;;
esac
SH
done
chmod +x "$TD/bin/"*
export PATH="$TD/bin:$PATH"
# Synthetic, ordinary-length tokens: the generic long-secret filter cannot hide them.
original=111111111111111111111111
wrong=222222222222222222222222
printf 'PROXY_AUTH_TOKEN=%s\nOTHER_SECRET=kept-fixture\n' "$original" >"$TD/.env"
chmod 600 "$TD/.env"
owner="$(stat -c '%u:%g' "$TD/.env")"
umask 022
_set_env_token ''
assert_rc "empty token replacement succeeds" "$?" 0
assert_eq "empty token env stays owner-only under umask 022" "$(stat -c %a "$TD/.env")" 600
_set_env_token "$original"
assert_rc "exact token replacement succeeds" "$?" 0
assert_eq "restored env stays owner-only" "$(stat -c %a "$TD/.env")" 600
assert_eq "owner and group survive replacement" "$(stat -c '%u:%g' "$TD/.env")" "$owner"
assert_eq "every temporary file was private before writing" "$(sort -u "$TD/modes")" 600
assert_eq "other environment secrets survive" "$(sed -n 's/^OTHER_SECRET=//p' "$TD/.env")" kept-fixture
assert_eq "token restored exactly" "$(sed -n 's/^PROXY_AUTH_TOKEN=//p' "$TD/.env")" "$original"
for tool in awk chown mv; do
    export AUTH_TEST_FAIL="$tool"
    _set_env_token "$wrong"
    assert_ne "$tool failure refuses replacement" "$?" 0
    assert_eq "$tool failure preserves original env" "$(sed -n 's/^PROXY_AUTH_TOKEN=//p' "$TD/.env")" "$original"
    assert_eq "$tool failure leaves no temporary file" "$(find "$TD" -name '.env.itest*' | wc -l | tr -d ' ')" 0
done
unset AUTH_TEST_FAIL
assert_eq "replacement failures preserve private mode" "$(stat -c %a "$TD/.env")" 600

# Run the real phase and assertion helpers; only live operations are stubbed.
env_on_box() { sed -n "s/^$1=//p" "$TD/.env"; }
pithead() {
    if [ "$1" = up ] && [ -z "$(env_on_box PROXY_AUTH_TOKEN)" ]; then
        echo 'refusing to start an unauthenticated xmrig-proxy control API'
        return 1
    fi
    return 0
}
wait_status_ok() { return 0; }
capture_artifacts() { touch "$TD/captured"; }
export OUT_DIR="$TD"
run_auth_fail_closed >"$TD/positive.log" 2>&1
assert_eq "successful phase preserves every assertion" "$IT_FAIL" 0
assert_eq "successful phase restores exact token" "$(env_on_box PROXY_AUTH_TOKEN)" "$original"
# Inject a wrong restoration through the same writer, leaving the phase comparison intact.
eval "$(declare -f _set_env_token | sed '1s/_set_env_token/_real_set_env_token/')"
_set_env_token() { _real_set_env_token "${1:+$wrong}"; }
(
    run_auth_fail_closed
    [ "$IT_FAIL" = 1 ] && [ -f "$TD/captured" ]
) >"$TD/negative.log" 2>&1
assert_rc "wrong restore is a counted failure with retained artifacts" "$?" 0
assert_contains "failure names exact restoration assertion" "$(cat "$TD/negative.log")" 'original PROXY_AUTH_TOKEN restored verbatim'
for token in "$original" "$wrong"; do
    grep -Fq "$token" "$TD/negative.log"
    assert_rc "neither fixture token reaches failed-restore output" "$?" 1
done
printf '%s passed, %s failed\n' "$IT_PASS" "$IT_FAIL"
[ "$IT_FAIL" = 0 ]
