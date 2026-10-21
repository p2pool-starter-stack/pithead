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

echo "== assert_egress_posture: INCONCLUSIVE detail retains every unreadable app (#2754) =="

for mode in local ssh; do
    for arm in tor tor-down; do
        if (
            IT_MODE="$mode"
            IT_REMOTE_DIR="/remote/pithead"
            rx() {
                case "$1" in
                "cat > "*) cat >/dev/null ;;
                "bash "*)
                    printf '%s\n' \
                        "[verify-egress] arm=tor stack=HEADER_SENTINEL" \
                        "  ! wallet-rpc: could not read live IPv4 TCP sockets (poll 1/3)" \
                        "  ✓ p2pool: 0 direct" "  ✓ monerod: 0 direct" \
                        "  ! dashboard: not running (poll 3/3)" \
                        "  ✓ tari: 0 direct" "  ✓ xmrig-proxy: 0 direct" \
                        "  · tor: 2 external relay connections" \
                        "[verify-egress] INCONCLUSIVE — a required sample was unreadable."
                    return 2
                    ;;
                esac
            }
            IT_FAIL=0
            out_file="$(mktemp)"
            trap 'rm -f "$out_file"' EXIT
            assert_egress_posture "$arm" >"$out_file" 2>&1
            [ "$IT_FAIL" -eq 1 ] &&
                grep -Fq "✗ egress verifier INCONCLUSIVE — could not run, not a detected leak (#274/#270)" "$out_file" &&
                grep -Fq "! wallet-rpc: could not read live IPv4 TCP sockets (poll 1/3)" "$out_file" &&
                grep -Fq "! dashboard: not running (poll 3/3)" "$out_file" &&
                grep -Fq "[verify-egress] INCONCLUSIVE — a required sample was unreadable." "$out_file" &&
                ! grep -Fq HEADER_SENTINEL "$out_file"
        ); then
            it_pass "$mode/$arm: inconclusive detail keeps every app diagnostic and verdict without the header"
        else
            it_fail "$mode/$arm: inconclusive detail keeps every app diagnostic and verdict without the header"
        fi
    done
done

echo "== assert_egress_posture: an unexpected verifier failure retains its diagnostic tail =="

if (
    IT_MODE=local
    IT_REMOTE_DIR="/remote/pithead"
    rx() {
        case "$1" in
        "bash "*)
            printf '%s\n' ignored-first ignored-second failure-third failure-fourth failure-fifth failure-last
            return 127
            ;;
        esac
    }
    IT_FAIL=0
    out_file="$(mktemp)"
    trap 'rm -f "$out_file"' EXIT
    assert_egress_posture >"$out_file" 2>&1
    [ "$IT_FAIL" -eq 1 ] &&
        grep -Fq "✗ egress verifier INCONCLUSIVE — could not run, not a detected leak (#274/#270)" "$out_file" &&
        grep -Fq failure-third "$out_file" && grep -Fq failure-last "$out_file" &&
        ! grep -Fq ignored-first "$out_file" && ! grep -Fq ignored-second "$out_file"
); then
    it_pass "an unexpected verifier failure remains inconclusive with its last four diagnostic lines"
else
    it_fail "an unexpected verifier failure remains inconclusive with its last four diagnostic lines"
fi

[ "$IT_FAIL" -eq 0 ]
