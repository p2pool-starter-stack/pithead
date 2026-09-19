#!/usr/bin/env bash
#
# Self-test for assert_egress_posture's --host (SSH) mode (#2302): a --host target need not carry
# a pithead git checkout at all — an appliance install ships only the deployed runtime, never the
# tests/ tree — so the harness must push bench-verify-egress.sh itself over the same connection
# rx already uses, rather than assume it exists at a repo-relative path on the target.
#
# Run: tests/integration/selftest/selftest-egress-push.sh
#
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=tests/integration/lib.sh
source "$HERE/../lib.sh"
INTEGRATION_RUN_SUITE=1
# shellcheck source=tests/integration/lib/run-matrix.sh
source "$HERE/../lib/run-matrix.sh"
# shellcheck source=tests/integration/lib/run-scenario.sh
source "$HERE/../lib/run-scenario.sh"

quote_arg() { printf '%q' "$1"; }
# run-scenario.sh resolves the local-mode script off run.sh's $HERE (the harness root), not
# selftest/'s own directory.
HERE="$HERE/.."

echo "== assert_egress_posture (--host/ssh mode): pushes the verifier instead of assuming a checkout (#2302) =="

if (
    IT_MODE="ssh"
    IT_REMOTE_DIR="/remote/pithead"
    log="$(mktemp)"
    pushed="$(mktemp)"
    trap 'rm -f "$log" "$pushed"' EXIT
    rx() { # fake target: env_on_box lookups (.env greps) return empty, so every clearnet-sync
        # gate defaults/skips harmlessly and execution reaches the bench push+run below.
        printf '%s\n' "$1" >>"$log"
        case "$1" in
        "cat > .itest-bench-verify-egress.sh") cat >"$pushed" ;;
        "bash .itest-bench-verify-egress.sh"*) printf '[verify-egress] OK\n' ;;
        esac
    }
    assert_egress_posture >/dev/null
    grep -qFx "cat > .itest-bench-verify-egress.sh" "$log" &&
        cmp -s "$pushed" "$HERE/benchmarks/bench-verify-egress.sh" &&
        grep -q "^bash .itest-bench-verify-egress.sh tor " "$log" &&
        grep -qFx "rm -f .itest-bench-verify-egress.sh" "$log"
); then
    it_pass "pushes the real verifier to a target-relative temp path, runs it, then removes it"
else
    it_fail "pushes the real verifier to a target-relative temp path, runs it, then removes it"
fi

echo "== assert_egress_posture: a push failure is INCONCLUSIVE, not a crash =="

if (
    IT_MODE="ssh"
    IT_REMOTE_DIR="/remote/pithead"
    rx() {
        case "$1" in
        "cat > "*)
            cat >/dev/null
            return 1
            ;;
        esac
    }
    IT_FAIL=0
    out_file="$(mktemp)"
    trap 'rm -f "$out_file"' EXIT
    assert_egress_posture >"$out_file" 2>&1 # not $(...): a command substitution subshell would
    # eat the IT_FAIL increment before this scope's own check of it below can see it.
    [ "$IT_FAIL" -eq 1 ] && grep -q INCONCLUSIVE "$out_file"
); then
    it_pass "a failed push is reported as an inconclusive (not leaked) verdict"
else
    it_fail "a failed push is reported as an inconclusive (not leaked) verdict"
fi

[ "$IT_FAIL" -eq 0 ]
