#!/usr/bin/env bash
# Prove the live probe rejects missing output, rather than passing on a command's exit alone.
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/../../.." && pwd)
# shellcheck source=tests/integration/lib/run-connection-announcements.sh
source "$ROOT/tests/integration/lib/run-connection-announcements.sh"
echo "== connection announcement probe fails closed =="
fixture=$(mktemp -d)
trap 'rm -rf -- "$fixture"' EXIT
openssl req -x509 -newkey rsa:2048 -nodes -keyout "$fixture/key.pem" -out "$fixture/cert.pem" -days 1 -subj /CN=fixture >/dev/null 2>&1
printf 'PROXY_TLS_DIR=%s\n' "$fixture" >"$fixture/.env"
printf '{"dashboard":{"host":"fixture-box"}}\n' >"$fixture/config.json"
cat >"$fixture/pithead" <<'FAKE'
#!/usr/bin/env bash
env_get() {
    case "$1" in
    STRATUM_BIND) echo 0.0.0.0 ;;
    HOST_IP) echo fixture-box ;;
    PROXY_STRATUM_PASSWORD) echo fixture.pool-pass ;;
    PROXY_STRATUM_TLS) echo true ;;
    PROXY_TLS_DIR) sed -n 's/^PROXY_TLS_DIR=//p' .env ;;
    esac
}
stratum_port_effective() { echo 3333; }
config_bool() { echo true; }
if [ "${BASH_SOURCE[0]}" = "$0" ]; then
    if [ "$1" = setup ] && [ "${FAIL_SETUP:-0}" = 1 ]; then
        echo 'Initializing Tor service'
        echo 'fixture-secret-must-not-be-retained'
        exit 42
    fi
    probe_command=$1
    if [ "$1" = apply ]; then
        count=$(cat apply-count 2>/dev/null || echo 0)
        echo "$((count + 1))" >apply-count
        [ "$count" -eq 0 ] || probe_command=no-change
    fi
    if [ "$1" = setup ]; then echo 'You can start the stack later with: ./pithead up'; fi
    if [ "$1" = apply ] && { [ "$probe_command" != "${OMIT_COMMAND:-}" ] || [ "${OMIT_FIELD:-}" != unchanged ]; }; then echo 'No configuration changes detected'; fi
    if [ "$probe_command" != "${OMIT_COMMAND:-}" ] || [ "${OMIT_FIELD:-}" != pool ]; then echo 'Pool URL: fixture-box:3333'; fi
    if [ "$probe_command" != "${OMIT_COMMAND:-}" ] || [ "${OMIT_FIELD:-}" != password ]; then echo 'Stratum password: fixture.pool-pass'; fi
    if [ "$probe_command" != "${OMIT_COMMAND:-}" ] || [ "${OMIT_FIELD:-}" != tls ]; then
        openssl x509 -in "$(env_get PROXY_TLS_DIR)/cert.pem" -noout -fingerprint -sha256 | cut -d= -f2 | tr -d ':' | tr '[:upper:]' '[:lower:]'
    fi
    if [ "$probe_command" != "${OMIT_COMMAND:-}" ] || [ "${OMIT_FIELD:-}" != miner ]; then echo 'Local miner opt-in is ON'; fi
fi
FAKE
chmod +x "$fixture/pithead"
probe=$(connection_announcements_snippet)
(cd "$fixture" && bash -c "$probe") >"$fixture/output" 2>&1
grep -Fq 'connections: no-change apply matches rendered credentials and preserves env' "$fixture/output"
echo 'PASS: complete connection probe executes its final assertion'
for command in setup up apply no-change; do
    for field in pool password tls miner; do
        rm -f "$fixture/apply-count"
        if (cd "$fixture" && OMIT_COMMAND="$command" OMIT_FIELD="$field" bash -c "$probe") >"$fixture/output" 2>&1; then
            echo "FAIL: missing $command $field was accepted" >&2
            exit 1
        fi
        echo "PASS: missing $command $field fails closed"
    done
done
rm -f "$fixture/apply-count"
if (cd "$fixture" && OMIT_COMMAND=no-change OMIT_FIELD=unchanged bash -c "$probe") >"$fixture/output" 2>&1; then
    echo 'FAIL: missing no-change-path assertion was accepted' >&2
    exit 1
fi
echo 'PASS: missing no-change-path assertion fails closed'

# Drive the outer harness too: a failed CLI must leave useful, credential-free evidence.
IT_FAIL=0
OUT_DIR=$fixture
rx() { (cd "$fixture" && FAIL_SETUP=1 bash -c "$1"); }
it_step() { :; }
assert_rc() { [ "$2" -eq "$3" ] || IT_FAIL=$((IT_FAIL + 1)); }
it_pass() { :; }
it_fail() { IT_FAIL=$((IT_FAIL + 1)); }
if run_connection_announcements; then
    echo 'FAIL: failed setup command was accepted' >&2
    exit 1
fi
grep -Fxq 'connection announcement probe exit: 42' "$fixture/connection-announcements.log"
grep -Fxq 'Failed at: setup' "$fixture/connection-announcements.log"
grep -Fxq 'Setup reached: Initializing Tor service' "$fixture/connection-announcements.log"
if grep -q 'fixture-secret' "$fixture/connection-announcements.log"; then
    echo 'FAIL: setup diagnostic retained a credential' >&2
    exit 1
fi
echo 'PASS: failed setup retains only the exit code and whitelisted stage labels'
