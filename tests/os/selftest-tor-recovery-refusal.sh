#!/usr/bin/env bash
# Pure guest-proof controls against the generated CLI; no containers or SSH.
set -euo pipefail
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
export TMPDIR="${TMPDIR:-${RUNNER_TEMP:?}}"
work=$(mktemp -d "${TMPDIR:?}/tor-recovery-refusal-selftest.XXXXXX")
trap 'rm -rf "$work"' EXIT
echo '== guest healthy Tor recovery refusal controls =='
mkdir -p "$work/stack/tor" "$work/stack/control" "$work/bin"
cp "$ROOT/pithead" "$work/stack/pithead"
printf 'DEPLOYMENT_COMPLETED=true\nTOR_DATA_DIR=%s\nCONTROL_DIR=%s\n' \
    "$work/stack/tor" "$work/stack/control" >"$work/stack/.env"
printf 'CircuitBuildTimeBin 1 2\n' >"$work/stack/tor/state"
cat >"$work/bin/sudo" <<'STUB'
#!/usr/bin/env bash
if [ "${SUDO_STATE_READ_FAIL:-0}" = 1 ] && [ "$1" = cat ]; then exit 2; fi
exec "$@"
STUB
cat >"$work/bin/docker" <<'STUB'
#!/usr/bin/env bash
case "$*" in
*'.Config.Labels'*) printf 'tor\n' ;;
*'.Source'*) printf '%s\n' "$TOR_FIXTURE_DATA" ;;
*'.Destination'*) printf 'x\n' ;;
*) echo 'unexpected Docker command in read-only fixture' >&2; exit 99 ;;
esac
STUB
cat >"$work/bin/awk" <<'STUB'
#!/usr/bin/env bash
[ "${STATE_PARSE_ERROR:-0}" = 0 ] || exit 2
exec /usr/bin/awk "$@"
STUB
chmod +x "$work/bin/"*
export PATH="$work/bin:$PATH" TOR_FIXTURE_DATA="$work/stack/tor"
sed "s|^cd /data/pithead$|cd '$work/stack'|" \
    "$ROOT/tests/os/tor-recovery-refusal-guest.sh" >"$work/guest.sh"
bash "$work/guest.sh" >"$work/pass" 2>"$work/errors" || {
    cat "$work/errors" >&2
    exit 1
}
grep -Fq 'PASS: guest healthy Tor recovery check' "$work/pass"
[ ! -s "$work/errors" ]
# Restore the pre-fix dispatch in the real generated CLI: the guest assertion must fail.
sed '/local _PITHEAD_TOR_RECOVERY_CLI=1/d' "$ROOT/pithead" >"$work/stack/pithead"
if bash "$work/guest.sh" >"$work/pre-fix" 2>&1; then
    echo 'FAIL: guest assertion accepted the pre-fix CLI' >&2
    exit 1
fi
grep -Fq 'unexpected-abort advice' "$work/pre-fix"
cp "$ROOT/pithead" "$work/stack/pithead"
printf 'CircuitBuildAbandonedCount 1000\nTotalBuildTimes 1000\n' >"$work/stack/tor/state"
if bash "$work/guest.sh" >"$work/saturated" 2>&1; then exit 1; fi
grep -Fq 'healthy-refusal precondition is not established' "$work/saturated"
cp "$ROOT/pithead" "$work/stack/pithead"
printf 'CircuitBuildTimeBin 1 2\n' >"$work/stack/tor/state"
for failure in read parse; do
    if [ "$failure" = read ]; then
        export SUDO_STATE_READ_FAIL=1
    else
        export STATE_PARSE_ERROR=1
    fi
    if bash "$work/guest.sh" >"$work/$failure-error" 2>&1; then exit 1; fi
    if [ "$failure" = read ]; then
        grep -Fq 'live Tor state could not be read' "$work/$failure-error"
    else
        grep -Fq 'Tor history classification failed' "$work/$failure-error"
    fi
    unset SUDO_STATE_READ_FAIL STATE_PARSE_ERROR
done
rm "$work/stack/tor/state"
if bash "$work/guest.sh" >"$work/missing-state" 2>&1; then exit 1; fi

# Execute the real provisioning prefix with fake transport; later legs cannot suppress this row.
eval "$(sed -n '/^_phase_provision_initial_body() {/,/    # The fresh-chain sync gate/p' "$ROOT/tests/os/phases/provision-initial.sh" | sed '$d')
}"
# shellcheck disable=SC2034 # The extracted provisioning function reads these globals.
SERIAL="$work/serial" SCRIPT_DIR="$ROOT/tests/os" jar="$work/jar" ip=fixture
printf 'pit-FIXTUR\n' >"$SERIAL"
info() { :; }
ok() { printf '%s\n' "$*" >>"$work/rows"; }
bad() { printf '%s\n' "$*" >>"$work/failed-rows"; }
_build_image() { echo fixture; }
_vm_boot_disk() { :; }
_wait_ssh() { :; }
_wait_setup_page() { :; }
phase_wizard_redirect() { :; }
stage_dashboard_exposure_addresses() { :; }
provision_node_preflight() { :; }
provision_setup_failure_recovery() { :; }
provision_browser_submit() { echo 200; }
wizard_miner_connection_card_valid() { :; }
provisioning_settled() { printf 'settled\n' >"$work/settled"; }
provisioning_setup_failed() { return 1; }
provisioning_state() { echo settled; }
curl() {
    case "$*" in
    *'/auth'*) printf 'wizard_session\n' >"$jar" ;;
    *'/api/handoff'*) printf '{"password":"%032d"}\n' 0 ;;
    *'/handoff-ack'*) echo 200 ;;
    *) echo 301 ;;
    esac
}
_ssh() {
    case "$*" in
    *'podman ps'*) echo 'dashboard caddy' ;;
    'timeout 40 bash -s')
        [ "$SSH_TIMEOUT" = 45 ] && [ -s "$work/settled" ] || return 91
        cat >"$work/streamed-script"
        return "$guest_rc"
        ;;
    esac
}
for guest_rc in 0 17; do
    rm -f "$work/rows" "$work/failed-rows" "$work/settled" "$work/streamed-script"
    _phase_provision_initial_body
    cmp "$ROOT/tests/os/tor-recovery-refusal-guest.sh" "$work/streamed-script"
    if [ "$guest_rc" = 0 ]; then
        grep -Fq 'guest healthy Tor recovery refusal exits 1' "$work/rows"
        [ ! -e "$work/failed-rows" ]
    else
        grep -Fq 'guest healthy Tor recovery refusal proof failed' "$work/failed-rows"
        if grep -Fq 'guest healthy Tor recovery refusal exits 1' "$work/rows"; then exit 1; fi
    fi
done
echo 'guest healthy Tor recovery refusal selftest PASS'
