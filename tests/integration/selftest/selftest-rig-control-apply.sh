#!/usr/bin/env bash
# Deterministic direct POST capture; no network, rig or Docker.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=tests/integration/lib.sh
source "$HERE/../lib.sh"
INTEGRATION_RUN_SUITE=1
# shellcheck source=tests/integration/lib/run-rig-reverse.sh
source "$HERE/../lib/run-rig-reverse.sh"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
mkdir "$WORK/bin" "$WORK/private"
export TMPDIR="$WORK/private"
export CURL_FLAGS="$WORK/curl-flags"
export CALLS="$WORK/calls" BODY_PATH="$WORK/body-path" CONFIG="$WORK/config"
export RESPONSE HTTP CURL_RC
cat >"$WORK/bin/curl" <<'CURL'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$1" >"$CURL_FLAGS"
printf 'POST\n' >>"$CALLS"
cat >"$CONFIG"
output='' previous=''
for arg; do
    [ "$previous" != -o ] || output="$arg"
    previous="$arg"
done
# Support the old stdout transport too, so regression failures name behavior.
if [ -z "$output" ]; then
    printf '%s' "$RESPONSE"
    exit "$CURL_RC"
fi
[ "$(ulimit -f)" -le 16 ] || exit 94
# Assert the actual private directory mode before it is cleaned up.
[ "$(stat -c %a "$(dirname "$output")")" = 700 ] || exit 96
printf '%s' "$output" >"$BODY_PATH"
printf '%s' "$RESPONSE" >"$output"
printf '%s' "$HTTP"
printf 'UNSAFE stderr credential topology\n' >&2
exit "$CURL_RC"
CURL
chmod +x "$WORK/bin/curl"
export PATH="$WORK/bin:$PATH"
export IT_MODE=local IT_REMOTE_DIR="$WORK" RIG_HOST=worker.invalid RIG_CONTROL_PORT=8082
IT_RIG_TOKEN=UNSAFE-token
check() { # <classification> <HTTP> <curl-exit> <body> [safe-status]
    local classification="$1" expected_status="${5:-absent}" out rc=0 diag
    HTTP="$2" CURL_RC="$3" RESPONSE="$4"
    : >"$CALLS"
    out="$(_rig_control_apply '{"max_temp_c":102}' 2>"$WORK/diagnostic")" || rc=$?
    diag="$(cat "$WORK/diagnostic")"
    assert_rc "$classification keeps the acceptance assertion reachable" "$rc" 0
    assert_eq "$classification disables user curl config" "$(cat "$CURL_FLAGS")" -q
    assert_eq "$classification sends exactly one POST" "$(wc -l <"$CALLS" | tr -d ' ')" 1
    assert_eq "$classification removes private response files" "$(ls -A "$TMPDIR")" ''
    if [ "$classification" = success ]; then
        assert_eq 'successful stdout is exactly the valid ID' "$out" 0123456789abcdef
        assert_eq 'success has no failure diagnostic' "$diag" ''
    else
        assert_eq "$classification has empty stdout" "$out" ''
        assert_contains "$classification is named" "$diag" "classification=$classification"
        assert_contains "$classification retains HTTP status" "$diag" "http_status=$HTTP"
        assert_contains "$classification retains curl exit" "$diag" "curl_exit=$CURL_RC"
        assert_contains "$classification status allowlist" "$diag" "response_status=$expected_status"
        [[ "$diag" =~ request_utc=[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z ]] || it_fail 'request UTC timestamp' 'missing or malformed'
        [[ "$diag" != *UNSAFE* && "$diag" != *worker.invalid* && "$diag" != *secret.invalid* ]] || it_fail 'diagnostic excludes hostile response and transport text' 'leaked fixture'
        [ "${#diag}" -lt 300 ] || it_fail 'diagnostic is bounded' 'too long'
    fi
}
echo "== direct rig POST classifications and constrained response fields =="
check success 202 0 '{"change_id":"0123456789abcdef","status":"accepted","error":"UNSAFE"}'
check http-refusal 401 0 '{"change_id":"0123456789abcdef","error":"UNSAFE"}'
check http-refusal 302 0 '<html>UNSAFE</html>'
check transport-failure 000 7 ''
check transport-failure 200 28 '{"change_id":"0123456789abcdef"}'
check empty-body 200 0 ''
check empty-body 200 0 $' \n\t'
check invalid-json 200 0 'UNSAFE not json'
check missing-valid-id 200 0 '{"status":"rejected","error":"UNSAFE"}' rejected
for body in '{}' 'null' '[]' '42' '"UNSAFE"' '{"change_id":42}' '{"change_id":true}' \
    '{"change_id":["0123456789abcdef"]}' '{"change_id":"0123456789abcdeF"}' \
    '{"change_id":"0123456789abcdef\n"}' '{"change_id":"UNSAFE@secret.invalid"}' \
    '{"change_id":"0123456789abcde"}' '{"status":"UNSAFE\u001b[31m"}' \
    '{"status":{"accepted":"UNSAFE"}}' '{"status":["accepted"]}' \
    '{} {"change_id":"0123456789abcdef"}'; do
    check missing-valid-id 200 0 "$body"
done
check missing-valid-id 200 0 '{"message":"UNSAFE","token":"UNSAFE","host":"secret.invalid","status":"accepted"}' accepted
for status in applied failed rolled_back noop; do
    check missing-valid-id 200 0 "{\"status\":\"$status\"}" "$status"
done
# An oversized write is killed or refused by the file limit; never parse its prefix.
RESPONSE="$(printf '%20000s' '' | tr ' ' x)" HTTP=200 CURL_RC=0
: >"$CALLS"
out="$(_rig_control_apply '{}' 2>"$WORK/diagnostic")"
assert_eq 'oversized response cannot produce an ID' "$out" ''
assert_contains 'oversized response is a transport failure' "$(cat "$WORK/diagnostic")" 'classification=transport-failure'
assert_eq 'oversized response is cleaned up' "$(ls -A "$TMPDIR")" ''
assert_eq 'oversized POST is not retried' "$(wc -l <"$CALLS" | tr -d ' ')" 1
# rx itself can fail before curl starts. Its stderr must also remain private.
rx() {
    cat >/dev/null
    echo 'UNSAFE SSH transport' >&2
    return 255
}
out="$(_rig_control_apply '{}' 2>"$WORK/diagnostic")"
assert_eq 'failed rx has empty stdout' "$out" ''
assert_contains 'failed rx does not invent a curl exit' "$(cat "$WORK/diagnostic")" 'curl_exit=unknown classification=transport-failure'
[[ "$(cat "$WORK/diagnostic")" != *UNSAFE* ]] || it_fail 'rx stderr is excluded' 'leaked fixture'
[ "$IT_FAIL" -eq 0 ]
