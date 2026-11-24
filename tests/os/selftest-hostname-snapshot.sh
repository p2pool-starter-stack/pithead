#!/usr/bin/env bash
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=tests/os/appliance-hostname-leg.sh
. "$HERE/appliance-hostname-leg.sh"
# shellcheck source=tests/os/appliance-config-approval-leg.sh
. "$HERE/appliance-config-approval-leg.sh"
f=0
(
    reads=$(mktemp) || exit 1
    trap 'rm -f "$reads"' EXIT
    sleep() { :; }
    row() { printf 'k\tk\te\ts\tc\tactive\tm\tcard\t%s' "$1"; }
    script=()
    hostname_runtime_snapshot() {
        local n
        n=$(($(cat "$reads") + 1))
        printf '%s' "$n" >"$reads"
        printf '%s' "${script[n - 1]:-${script[${#script[@]} - 1]}}"
    }
    run() {
        printf 0 >"$reads"
        script=("$@")
    }
    hostname_snapshot_complete "$(row 1)" || exit 1
    hostname_snapshot_complete "" && exit 1
    hostname_snapshot_complete "$(printf 'k\t\te\ts\tc\tactive\tm\tcard\t1')" && exit 1
    hostname_snapshot_complete "$(printf 'k\tk\te\ts\tc\tactive\tm\tcard\t')" && exit 1
    run "$(row 1)" "$(row 1)"
    [ "$(hostname_stable_snapshot l)" = "$(row 1)" ] && [ "$(cat "$reads")" = 2 ] || exit 1
    run "$(row 1)" "$(row 2)" "$(row 2)"
    [ "$(hostname_stable_snapshot l)" = "$(row 2)" ] && [ "$(cat "$reads")" = 3 ] || exit 1
    run "$(printf 'k\t\te\ts\tc\tactive\tm\tcard\t1')"
    hostname_stable_snapshot l >/dev/null && exit 1
    [ "$(cat "$reads")" = 12 ] || exit 1
    inc=$(printf 'k\tk\te\t\tc\tactive\tm\tcard\t1')
    run "$inc" "$(row 1)" "$(row 1)" "$(row 1)" "$(row 1)"
    out=$(hostname_snapshot_unchanged l "$(row 1)") || exit 1
    [ "$out" = "$(row 1)" ] && [ "$(cat "$reads")" = 5 ] || exit 1
    run "$(row 1)" "$(row 1)" "$(row 2)"
    out=$(hostname_snapshot_unchanged l "$(row 1)") && exit 1
    [ "$out" = "$(row 2)" ] && [ "$(cat "$reads")" = 3 ] || exit 1
    run "$inc"
    hostname_snapshot_unchanged l "$(row 1)" >/dev/null && exit 1
    [ "$(cat "$reads")" = 10 ] || exit 1
    run "$(row 1)"
    hostname_snapshot_unchanged l "$(row 1)" >/dev/null || exit 1
    [ "$(cat "$reads")" = 4 ] || exit 1
    [ "$(hostname_snapshot_diff "$(row 1)" "$(row 1)")" = none ] || exit 1
    [ "$(hostname_snapshot_diff "$(row 1)" "$(row 2)")" = 'avahi-started: 1 -> 2' ] || exit 1
    [ "$(hostname_snapshot_diff "$(row 1)" "$(printf 'k\tk\te\t\tc\tactive\tm\tcard\t1')")" = 'state: s -> empty' ] || exit 1
) || f=$((f + 1))
(
    ip=192.0.2.10 handoff_body='{}' verdicts=""
    sleep() { :; }
    assert_appliance_hostname_identity() { return 0; }
    dashboard_curl() { printf '{"dashboard":{"host":"fixture-box"}}'; }
    dashboard_control_request() { printf '{"status":"previewed","approval_required":true}'; }
    hostname_stable_snapshot() { printf 'one'; }
    ok() { verdicts+="ok:$1;"; }
    bad() { verdicts+="bad:$1;"; }
    hostname_snapshot_unchanged() { printf 'one'; }
    phase_provision_hostname_regressions user password
    case "$verdicts" in *'ok:day-two hostname preview is approval-gated'*) ;; *) exit 1 ;; esac
    case "$verdicts" in *'bad:'*) exit 1 ;; esac
    verdicts=""
    hostname_snapshot_unchanged() {
        printf 'two'
        return 1
    }
    hostname_snapshot_diff() { printf 'avahi-started: 1 -> 2'; }
    phase_provision_hostname_regressions user password
    case "$verdicts" in *'bad:day-two hostname preview mutated identity'*'identity diff: avahi-started: 1 -> 2'*) ;; *) exit 1 ;; esac
    case "$verdicts" in *'ok:day-two hostname preview is approval-gated'*) exit 1 ;; esac
    verdicts=""
    hostname_snapshot_unchanged() { printf 'one'; }
    dashboard_control_request() { printf '{"status":"applied","approval_required":false}'; }
    phase_provision_hostname_regressions user password
    case "$verdicts" in *'bad:day-two hostname preview mutated identity'*'preview: {"status":"applied","approval_required":false}'*) ;; *) exit 1 ;; esac
    verdicts=""
    dashboard_control_request() { printf '{"status":"previewed","approval_required":true}'; }
    dashboard_curl() { printf '{"dashboard":{"host":"fixture-next"}}'; }
    phase_provision_hostname_regressions user password
    case "$verdicts" in *'bad:day-two hostname preview mutated identity'*'configured host: fixture-next'*) ;; *) exit 1 ;; esac
    verdicts=""
    dashboard_curl() { printf '{"dashboard":{"host":"fixture-box"}}'; }
    hostname_stable_snapshot() {
        printf 'unsettled'
        return 1
    }
    phase_provision_hostname_regressions user password
    case "$verdicts" in *'bad:hostname preview: identity never settled before the preview (unsettled)'*) ;; *) exit 1 ;; esac
    case "$verdicts" in *'ok:day-two hostname preview is approval-gated'*) exit 1 ;; esac
) || f=$((f + 1))
_refusal_drift() (
    local verdicts="" ip=fixture-address
    sensitive_live_config() { printf '{"dashboard":{"host":"fixture-box"}}'; }
    dashboard_curl() { printf 'cfg?._config_version_newer ? "Saving is blocked" : null'; }
    hostname_stable_snapshot() { printf one; }
    hostname_snapshot_unchanged() {
        printf two
        return 1
    }
    hostname_snapshot_diff() { printf 'avahi-started: 1 -> 2'; }
    sensitive_preview() {
        APPROVAL_PREVIEW='{"id":"r1","status":"previewed"}'
        APPROVAL_REQUEST_ID=r1
    }
    dashboard_control_request() { printf '{"status":"rejected","error":"typed payout confirmations"}'; }
    ok() { verdicts+="ok:$1;"; }
    bad() { verdicts+="bad:$1;"; }
    phase_provision_sensitive_regressions fixture-user fixture-password
    case "$verdicts" in
    *'bad:day-two hostname crossed the confirmation gate'*'identity diff: avahi-started: 1 -> 2'*) ;;
    *) return 1 ;;
    esac
    case "$verdicts" in *'ok:day-two hostname commit is refused'*) return 1 ;; esac
)

_refusal_drift || f=$((f + 1))
[ "$f" -eq 0 ] || {
    printf 'selftest-hostname-snapshot FAILED: %s checks\n' "$f"
    exit 1
}
printf 'selftest-hostname-snapshot passed\n'
