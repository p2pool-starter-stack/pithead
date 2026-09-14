#!/usr/bin/env bash
# Guards the #2214 fix: aquasecurity/setup-trivy's installer occasionally fails to fetch the
# Trivy binary from GitHub Releases (a transient upstream outage, not a CVE finding), and that
# failure used to red every `aquasecurity/trivy-action` step in the gate workflows on every run.
# The fix is a cached, version-pinned install step (.github/actions/install-trivy) placed
# immediately before each trivy-action step, with `skip-setup-trivy: true` so trivy-action reuses
# that binary instead of re-running its own copy of the same installer. This script fails if any
# gate workflow's count of trivy-action steps, install-trivy steps, and skip-setup-trivy: true
# lines ever drifts apart — a new call site missing the fix, or one that lost it.
#
# Run with --self-test first.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
GATE_WORKFLOWS="$ROOT/.github/workflows/ci.yml $ROOT/.github/workflows/os-rootfs.yml $ROOT/.github/workflows/test-images.yml"

# -> one line per gate workflow naming its three counts, rc 0 only if every file has all three
# equal AND at least one trivy-action step (a file with zero of everything would otherwise pass
# vacuously).
check_installer_cache() {
    local f base n_trivy n_install n_skip fail=0
    for f in $GATE_WORKFLOWS; do
        base="$(basename "$f")"
        if [ ! -f "$f" ]; then
            echo "$base: NOFILE"
            fail=1
            continue
        fi
        # `|| true` on each: a zero-match grep -c exits 1, and under `set -e` an unguarded
        # `var=$(grep -c ...)` at top level kills the whole script right here — silently, before
        # the MISMATCH line or the Fix: hint ever print, and before the loop reaches the other
        # workflow files. That defeats the one thing this script exists to add over a bare
        # workflow failure: a named diagnostic. Exactly this case (a missing install-trivy step,
        # or a missing skip-setup-trivy: true) is what the self-test below asserts on.
        n_trivy=$(grep -c 'uses:.*aquasecurity/trivy-action@' "$f" || true)
        n_install=$(grep -c 'uses:[[:space:]]*\./.github/actions/install-trivy' "$f" || true)
        n_skip=$(grep -c 'skip-setup-trivy:[[:space:]]*true' "$f" || true)
        if [ "$n_trivy" -eq 0 ] || [ "$n_trivy" -ne "$n_install" ] || [ "$n_trivy" -ne "$n_skip" ]; then
            echo "$base: MISMATCH — $n_trivy trivy-action step(s), $n_install install-trivy step(s), $n_skip skip-setup-trivy: true line(s)"
            fail=1
        else
            echo "$base: $n_trivy trivy-action step(s), all paired with install-trivy + skip-setup-trivy"
        fi
    done
    if [ "$fail" -eq 1 ]; then
        echo "Fix: every aquasecurity/trivy-action step needs one '- uses: ./.github/actions/install-trivy'" \
            "step and one 'skip-setup-trivy: true' in its with: block (#2214)."
    fi
    return "$fail"
}

# --- --self-test ----------------------------------------------------------------------------
if [ "${1:-}" = "--self-test" ]; then
    tmp="$(mktemp -d)"
    trap 'rm -rf "$tmp"' EXIT
    pass=0
    fail_ct=0
    st() {
        local desc="$1" got="$2" want="$3"
        if [ "$got" = "$want" ]; then
            echo "  self-test ok: $desc"
            pass=$((pass + 1))
        else
            echo "  self-test FAIL: $desc (got [$got], want [$want])"
            fail_ct=$((fail_ct + 1))
        fi
    }
    write_file() {
        # $1 = file, $2 = 1 to include the install-trivy step, $3 = 1 to include skip-setup-trivy
        {
            echo "jobs:"
            echo "  j:"
            echo "    steps:"
            [ "$2" = "1" ] && echo "      - uses: ./.github/actions/install-trivy"
            echo "      - name: Scan image for CVEs (Trivy)"
            echo "        uses: aquasecurity/trivy-action@0000000000000000000000000000000000000000 # v0.36.0"
            echo "        with:"
            [ "$3" = "1" ] && echo "          skip-setup-trivy: true"
            echo "          version: v0.74.0"
        } >"$1"
    }

    ok_a="$tmp/ci.yml"
    ok_b="$tmp/os-rootfs.yml"
    ok_c="$tmp/test-images.yml"
    write_file "$ok_a" 1 1
    write_file "$ok_b" 1 1
    write_file "$ok_c" 1 1
    GATE_WORKFLOWS="$ok_a $ok_b $ok_c"
    rc=0
    out="$(check_installer_cache)" || rc=$?
    st "all three paired -> rc 0" "$rc" "0"
    st "reports the pair count for ci.yml" \
        "$(printf '%s\n' "$out" | grep -c 'ci.yml: 1 trivy-action step(s), all paired')" "1"

    missing_install="$tmp/ci2.yml"
    write_file "$missing_install" 0 1
    GATE_WORKFLOWS="$missing_install $ok_b $ok_c"
    rc=0
    out="$(check_installer_cache)" || rc=$?
    st "missing install step -> rc 1" "$rc" "1"
    # Asserted on TEXT, not just rc: rc alone doesn't catch a `set -e` kill mid-loop, which
    # produces the same rc=1 with zero diagnostic output — the exact bug that shipped once.
    st "missing install step -> names the file and the 0-vs-1 mismatch" \
        "$(printf '%s\n' "$out" | grep -c 'ci2.yml: MISMATCH — 1 trivy-action step(s), 0 install-trivy step(s)')" "1"
    st "missing install step -> still reaches and reports the other two files" \
        "$(printf '%s\n' "$out" | grep -c 'all paired')" "2"
    st "missing install step -> prints the Fix: hint" \
        "$(printf '%s\n' "$out" | grep -c '^Fix: ')" "1"

    missing_skip="$tmp/ci3.yml"
    write_file "$missing_skip" 1 0
    GATE_WORKFLOWS="$missing_skip $ok_b $ok_c"
    rc=0
    out="$(check_installer_cache)" || rc=$?
    st "missing skip-setup-trivy -> rc 1" "$rc" "1"
    st "missing skip-setup-trivy -> names the file and the 0-vs-1 mismatch" \
        "$(printf '%s\n' "$out" | grep -c 'ci3.yml: MISMATCH — 1 trivy-action step(s), 1 install-trivy step(s), 0 skip-setup-trivy: true line(s)')" "1"

    no_step="$tmp/ci4.yml"
    printf 'jobs:\n  j:\n    steps:\n      - run: echo hi\n' >"$no_step"
    GATE_WORKFLOWS="$no_step $ok_b $ok_c"
    rc=0
    out="$(check_installer_cache)" || rc=$?
    st "no trivy-action step at all -> rc 1 (never a vacuous pass)" "$rc" "1"
    st "no trivy-action step at all -> names the 0-vs-0-vs-0 mismatch, not a silent kill" \
        "$(printf '%s\n' "$out" | grep -c 'ci4.yml: MISMATCH — 0 trivy-action step(s)')" "1"

    echo "lint-trivy-installer-cache self-test: $pass ok, $fail_ct failed"
    [ "$fail_ct" -eq 0 ]
    exit $?
fi

check_installer_cache
