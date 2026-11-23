#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=tests/os/lib/redact-addr.sh
. "$SCRIPT_DIR/lib/redact-addr.sh"
# shellcheck source=tests/os/appliance-lan-guard-leg.sh
. "$SCRIPT_DIR/appliance-lan-guard-leg.sh"
work=$(mktemp -d "${TMPDIR:-/tmp}/lan-guard-apply.XXXXXX")
trap 'rm -rf "$work"' EXIT
info() { :; }
bad() { printf '%s\n' "$*" >>"$work/bad"; }
ok() { printf '%s\n' "$*" >>"$work/ok"; }
_control_requests_drained() { return 0; }
approval_capture_restore_snapshot() { return 0; }
approval_restore_pending() { printf 'restored\n' >>"$work/restored"; }
addr=4$(printf 'A%.0s' $(seq 94))
_ssh() {
    case "$*" in
    true) return 0 ;;
    *lan-guard-apply.log*)
        printf 'apply: tari wallet quadlet did not settle\n'
        printf 'address %s\n' "$addr"
        return 7
        ;;
    esac
    return 1
}
phase_provision_lan_guard 0 2>"$work/err"
grep -Fq 'did not accept the three LAN switches (exit 7)' "$work/bad"
grep -Fq 'apply: tari wallet quadlet did not settle' "$work/err"
if grep -Fq "$addr" "$work/err"; then exit 1; fi
grep -Fq 'address [redacted-address]' "$work/err"
[ "$(wc -l <"$work/restored" | tr -d ' ')" = 1 ]
printf 'selftest-lan-guard-apply-output: PASS\n'
