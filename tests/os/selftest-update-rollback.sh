#!/usr/bin/env bash
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export OS_RUN_SUITE=1
source "$HERE/phases/update-rollback-leg.sh"
export DASH_USER=fixture DASH_PASS=fixture ip=fixture.example
sleep() { :; }
_ssh() { return "$doctor_rc"; }
curl() { printf '%s' "$http_code"; }
doctor_rc=0 http_code=200
_update_rollback_serves
doctor_rc=1
if _update_rollback_serves; then
    echo 'accepted failed doctor' >&2
    exit 1
fi
doctor_rc=0 http_code=401
if _update_rollback_serves; then
    echo 'accepted refused login' >&2
    exit 1
fi
http_code=200
_marker() { printf 'v2\n'; }
_ssh() {
    if [ "$*" = 'cat /etc/pithead-test-marker' ]; then printf '%s' "$guest_marker"; else return "$commit_rc"; fi
}
guest_marker=v3rollback commit_rc=0
_update_wait_committed v3rollback
guest_marker=v2
if _update_wait_committed v3rollback; then
    echo 'accepted wrong slot' >&2
    exit 1
fi
guest_marker=v3rollback commit_rc=1
if _update_wait_committed v3rollback; then
    echo 'accepted uncommitted slot' >&2
    exit 1
fi
info() { :; }
ok() { :; }
bad() { failures=$((failures + 1)); }
it_skip_leg() { missing=$((missing + 1)); }
_update_wait_committed() { return "$commit_rc"; }
_identity_snapshot() { printf 'fixture'; }
_identity_unchanged() { :; }
_build_bundle() { printf 'bundle'; }
_stage_bundle() { :; }
_ssh() { :; }
_reboot_wait() { actions="$actions $*"; }
_rollback_cmd() { printf 'rollback'; }
_update_rollback_serves() { return "$serve_rc"; }
export LEG4_PITHEAD_BOOT_PROVED=1
commit_rc=0 serve_rc=0 failures=0 missing=0 actions=""
phase_update_rollback_leg
[ "$failures" = 0 ] && [ "$missing" = 0 ] && [ "$actions" = ' reboot 300 rollback 300' ]
serve_rc=1 failures=0 actions=""
phase_update_rollback_leg
[ "$failures" = 1 ] && [ "$actions" = ' reboot 300 rollback 300' ]
LEG4_PITHEAD_BOOT_PROVED=0 failures=0 actions=""
phase_update_rollback_leg
[ "$failures" = 0 ] && [ "$missing" = 1 ] && [ -z "$actions" ]
LEG4_PITHEAD_BOOT_PROVED=1 commit_rc=1 failures=0 actions=""
phase_update_rollback_leg
[ "$failures" = 1 ] && [ -z "$actions" ]
printf 'update-rollback: PASS\n'
