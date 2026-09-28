#!/usr/bin/env bash
# Holds the shape that makes #1290's parity gate mean something after #2214.
#
# The gate workflows install trivy ONCE, up front, via ./.github/actions/install-trivy, and every
# trivy-action step (primary and retry) then passes `skip-setup-trivy: true`. So the ONE line that
# decides which engine runs is the caller's install-trivy `version:` — the line
# scripts/watch/trivyignore-watch.sh --check-parity reads. This script fails if anything breaks
# that chain:
#
#   1. counts per gate workflow: trivy-action steps == install-trivy steps == skip-setup-trivy: true
#   2. no `version:` inside a gate workflow's trivy-action step — with skip-setup-trivy it is never
#      resolved, so it would be an inert value sitting where a reader (and, before #2214's review,
#      the parity gate itself) takes it for the live one
#   3. no literal pin inside either composite action: install-trivy must pass `${{ inputs.version }}`
#      through to setup-trivy, and retry-trivy-scan must declare no version at all
#   4. the bump test the whole thing exists for: resolve_engine() traces a caller's literal through
#      the composite to what setup-trivy is handed, and --self-test proves that bumping that
#      literal (what the gate's own `Fix:` hint tells you to do) moves the resolved engine with it.
#
# Run with --self-test first.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
GATE_WORKFLOWS="$ROOT/.github/workflows/ci.yml $ROOT/.github/workflows/os-rootfs.yml $ROOT/.github/workflows/test-images.yml"
INSTALL_ACTION="$ROOT/.github/actions/install-trivy/action.yml"
RETRY_ACTION="$ROOT/.github/actions/retry-trivy-scan/action.yml"

# <workflow> -> every `version:` literal passed to an install-trivy step, one per line. Awk state
# machine: an install-trivy `uses:` line opens a step, the next list item closes it, so a later
# step's own version: is never attributed here.
install_versions() {
    awk '
        /^[[:space:]]*(-[[:space:]]+)?uses:[[:space:]]*\.\/\.github\/actions\/install-trivy([[:space:]]|$)/ { instep = 1; next }
        instep && /^[[:space:]]*version:[[:space:]]*/ {
            v = $0
            sub(/^[[:space:]]*version:[[:space:]]*/, "", v)
            sub(/[[:space:]]*#.*$/, "", v)
            sub(/[[:space:]]*$/, "", v)
            print v
            next
        }
        instep && /^[[:space:]]*-[[:space:]]/ { instep = 0 }
    ' "$1"
}

# <workflow> -> the engine version that workflow ACTUALLY installs, or a REFUSED/... reason. This
# is the trace the bump test asserts on: the caller's literal is only the answer while the
# composite forwards `${{ inputs.version }}`; a literal pin inside the composite would make the
# caller's line decorative, so that case refuses rather than reporting the caller's value.
resolve_engine() {
    local wf="$1" vers pinned
    vers="$(install_versions "$wf" | sort -u)"
    [ -n "$vers" ] || {
        echo "REFUSED: no install-trivy version: in $(basename "$wf")"
        return 0
    }
    [ "$(printf '%s\n' "$vers" | wc -l)" -eq 1 ] || {
        echo "REFUSED: $(basename "$wf") passes more than one version"
        return 0
    }
    # every version: handed to setup-trivy inside the composite must be the input, never a literal
    pinned="$(awk '/^runs:/ { inruns = 1 } inruns && /^[[:space:]]*version:[[:space:]]*/ && $0 !~ /\$\{\{[[:space:]]*inputs\.version[[:space:]]*\}\}/ { print }' "$INSTALL_ACTION")"
    [ -z "$pinned" ] && {
        printf '%s\n' "$vers"
        return 0
    }
    echo "REFUSED: install-trivy pins a version of its own; the caller's literal is decorative"
}

# -> one line per gate workflow plus one per composite action, rc 0 only if the whole chain holds.
check_installer_cache() {
    local f base n_trivy n_install n_skip n_inert fail=0 engine
    for f in $GATE_WORKFLOWS; do
        base="$(basename "$f")"
        if [ ! -f "$f" ]; then
            echo "$base: NOFILE"
            fail=1
            continue
        fi
        # `|| true` on each: a zero-match grep -c exits 1, and under `set -e` an unguarded
        # `var=$(grep -c ...)` would kill the script here — silently, before any diagnostic or the
        # Fix: hint prints, and before the loop reaches the other workflows.
        n_trivy=$(grep -c 'uses:.*aquasecurity/trivy-action@' "$f" || true)
        n_install=$(grep -c 'uses:[[:space:]]*\./.github/actions/install-trivy' "$f" || true)
        n_skip=$(grep -c 'skip-setup-trivy:[[:space:]]*true' "$f" || true)
        # a version: in a trivy-action step is inert under skip-setup-trivy — install_versions()
        # only ever attributes one to an install-trivy step, so any surplus lives in a scan step.
        n_inert=$(($(grep -c '^[[:space:]]*version:[[:space:]]' "$f" || true) - $(install_versions "$f" | wc -l | tr -d ' ')))
        engine="$(resolve_engine "$f")"
        if [ "$n_trivy" -eq 0 ] || [ "$n_trivy" -ne "$n_install" ] || [ "$n_trivy" -ne "$n_skip" ]; then
            echo "$base: MISMATCH — $n_trivy trivy-action step(s), $n_install install-trivy step(s), $n_skip skip-setup-trivy: true line(s)"
            fail=1
        elif [ "$n_inert" -ne 0 ]; then
            echo "$base: INERT PIN — $n_inert version: line(s) outside an install-trivy step; with skip-setup-trivy nothing resolves them"
            fail=1
        elif [ "${engine#REFUSED}" != "$engine" ]; then
            echo "$base: $engine"
            fail=1
        else
            echo "$base: $n_trivy scan step(s), engine $engine, decided by the install-trivy version: the parity gate reads"
        fi
    done
    if grep -q 'skip-setup-trivy:[[:space:]]*true' "$RETRY_ACTION" && ! grep -qE '^[[:space:]]*version:[[:space:]]' "$RETRY_ACTION"; then
        echo "retry-trivy-scan: re-scans with the installed binary, declares no version of its own"
    else
        echo "retry-trivy-scan: MISMATCH — it must set skip-setup-trivy: true and declare no version: (a second, ungated pin)"
        fail=1
    fi
    if [ "$fail" -eq 1 ]; then
        echo "Fix: install trivy once per job via ./.github/actions/install-trivy with the version: the parity gate reads," \
            "and give every trivy-action step skip-setup-trivy: true and no version: of its own (#1290, #2214)."
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
    write_file() { # <path> <install-step:0|1> <skip-setup:0|1> <version> [inert-version-in-scan-step]
        {
            echo "jobs:"
            echo "  j:"
            echo "    steps:"
            if [ "$2" = "1" ]; then
                echo "      - uses: ./.github/actions/install-trivy"
                echo "        with:"
                echo "          version: $4"
            fi
            echo "      - name: Scan image for CVEs (Trivy)"
            echo "        uses: aquasecurity/trivy-action@0000000000000000000000000000000000000000 # v0.36.0"
            echo "        with:"
            [ "$3" = "1" ] && echo "          skip-setup-trivy: true"
            [ -n "${5:-}" ] && echo "          version: $5"
            echo "          image-ref: pithead-example:ci"
        } >"$1"
    }
    write_composite() { # <path> <forwards-input:0|1>
        {
            echo "inputs:"
            echo "  version:"
            echo "    required: true"
            echo "runs:"
            echo "  using: composite"
            echo "  steps:"
            echo "    - uses: aquasecurity/setup-trivy@0000000000000000000000000000000000000000"
            echo "      with:"
            [ "$2" = "1" ] && echo "        version: \${{ inputs.version }}"
            [ "$2" = "0" ] && echo "        version: v0.73.0"
            echo "        cache: true"
        } >"$1"
    }
    ok_a="$tmp/ci.yml"
    ok_b="$tmp/os-rootfs.yml"
    ok_c="$tmp/test-images.yml"
    for f in "$ok_a" "$ok_b" "$ok_c"; do write_file "$f" 1 1 v0.73.0; done
    INSTALL_ACTION="$tmp/install.yml"
    write_composite "$INSTALL_ACTION" 1
    RETRY_ACTION="$tmp/retry.yml"
    printf 'runs:\n  steps:\n    - with:\n        skip-setup-trivy: true\n' >"$RETRY_ACTION"
    GATE_WORKFLOWS="$ok_a $ok_b $ok_c"
    rc=0
    out="$(check_installer_cache)" || rc=$?
    st "whole chain intact -> rc 0" "$rc" "0"
    st "names the engine the gated literal decides" \
        "$(printf '%s\n' "$out" | grep -c 'ci.yml: 1 scan step(s), engine v0.73.0')" "1"

    # THE bump test: follow the gate's own Fix: hint on the gated line, and the engine that is
    # actually installed moves with it. That is the property three review rounds were about.
    st "before the bump, the caller installs v0.73.0" "$(resolve_engine "$ok_a")" "v0.73.0"
    write_file "$ok_a" 1 1 v0.75.0
    st "bumping the gated version: moves the engine that actually runs" "$(resolve_engine "$ok_a")" "v0.75.0"
    write_file "$ok_a" 1 1 v0.73.0

    # ... and it only moves it while the composite forwards the input. A literal pin there would
    # make the gated line decorative — exactly the defect this shape replaced — so refuse.
    write_composite "$INSTALL_ACTION" 0
    st "a literal pin inside the composite refuses rather than reporting the caller's value" \
        "$(resolve_engine "$ok_a" | cut -d: -f1)" "REFUSED"
    rc=0
    check_installer_cache >/dev/null || rc=$?
    st "and that refusal fails the gate" "$rc" "1"
    write_composite "$INSTALL_ACTION" 1

    write_file "$ok_a" 0 1 v0.73.0
    rc=0
    out="$(check_installer_cache)" || rc=$?
    st "missing install step -> rc 1" "$rc" "1"
    st "missing install step -> names the 1-vs-0 mismatch" \
        "$(printf '%s\n' "$out" | grep -c 'ci.yml: MISMATCH — 1 trivy-action step(s), 0 install-trivy step(s)')" "1"
    st "missing install step -> still reports the other two files" \
        "$(printf '%s\n' "$out" | grep -c 'engine v0.73.0')" "2"
    st "missing install step -> prints the Fix: hint" "$(printf '%s\n' "$out" | grep -c '^Fix: ')" "1"

    write_file "$ok_a" 1 0 v0.73.0
    rc=0
    out="$(check_installer_cache)" || rc=$?
    st "missing skip-setup-trivy -> rc 1" "$rc" "1"
    st "missing skip-setup-trivy -> names the 0 skip line(s)" \
        "$(printf '%s\n' "$out" | grep -c '0 skip-setup-trivy: true line(s)')" "1"

    write_file "$ok_a" 1 1 v0.73.0 v0.73.0
    rc=0
    out="$(check_installer_cache)" || rc=$?
    st "an inert version: in the scan step -> rc 1" "$rc" "1"
    st "an inert version: is named as such, not as a mismatch" \
        "$(printf '%s\n' "$out" | grep -c 'ci.yml: INERT PIN — 1 version: line(s)')" "1"
    write_file "$ok_a" 1 1 v0.73.0

    printf 'runs:\n  steps:\n    - with:\n        version: v0.73.0\n' >"$RETRY_ACTION"
    rc=0
    out="$(check_installer_cache)" || rc=$?
    st "a second pin in retry-trivy-scan -> rc 1" "$rc" "1"
    st "and it is named as an ungated second pin" \
        "$(printf '%s\n' "$out" | grep -c 'retry-trivy-scan: MISMATCH')" "1"

    echo "lint-trivy-installer-cache self-test: $pass ok, $fail_ct failed"
    [ "$fail_ct" -eq 0 ]
    exit $?
fi

check_installer_cache
