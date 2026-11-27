#!/usr/bin/env bash
# == Caddy failure diagnostics ==
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=tests/os/caddy-failure-evidence.sh
. "$SCRIPT_DIR/caddy-failure-evidence.sh"
# shellcheck source=tests/os/appliance-tari-mode-leg.sh
. "$SCRIPT_DIR/appliance-tari-mode-leg.sh"
python3 "$SCRIPT_DIR/test_caddy_failure_evidence.py"
dir=$(mktemp -d)
trap 'rm -rf "$dir"' EXIT
_ssh() {
    [ "${SSH_TIMEOUT:-}" = 7 ] || return 1
    [ "$*" = 'python3 -' ] || return 1
    cmp -s - "$SCRIPT_DIR/caddy-failure-evidence.py" || return 1
    printf '{"state":{"ExitCode":1}}'
}
SSH_PROBE_TIMEOUT=7 caddy_failure_evidence 2>"$dir/snapshot"
grep -Fxq '  Caddy failure snapshot: {"state":{"ExitCode":1}}' "$dir/snapshot"
_ssh() { return 255; }
caddy_failure_evidence 2>"$dir/unavailable"
grep -Fxq '  Caddy failure snapshot: unavailable (ssh exit 255)' "$dir/unavailable"
_ssh() { printf 'not-json'; }
caddy_failure_evidence 2>"$dir/invalid"
grep -Fxq '  Caddy failure snapshot: unavailable (ssh exit 0)' "$dir/invalid"
# Drive the real failure branch: diagnostics must not turn the prerequisite failure green
# or enter a switch/commit, including when an earlier row already failed.
tari_live_config() { return 1; }
bad() { printf 'bad: %s\n' "$1"; }
info() { printf 'info: %s\n' "$1"; }
for phase_rc in 0 1; do
    phase_provision_tari_mode_switch fixture fixture "$phase_rc" >"$dir/row" 2>"$dir/evidence"
    grep -Fq 'switching was NOT exercised' "$dir/row"
    [ "$(grep -c 'Caddy failure snapshot: unavailable' "$dir/evidence")" -eq 2 ]
done
grep -Fq '. "$SCRIPT_DIR/caddy-failure-evidence.sh"' "$SCRIPT_DIR/run.sh"
printf 'selftest-caddy-failure-evidence: PASS\n'
