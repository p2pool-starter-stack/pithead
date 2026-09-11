#!/usr/bin/env bash
# Evidence for the one row five battery legs report identically and none of them read (#2060):
# a bundle build failed, and the assertion names the log path instead of the log. Sourced by
# tests/os/run.sh; uses its indentation idiom. Kept out of failure-evidence.sh so that file's
# ceiling is not the reason this dump has to be small (the zero-container-evidence.sh precedent).
#
# The build runs on the HOST, not the guest, so this is a local file read — no transport, nothing
# to lose when the VM is recycled. That is exactly why the missing payload was expensive: the
# evidence was on the bench the whole time and the row told nobody to look at it.
#
# Three outcomes, three sentences, because "nothing to show" and "nothing went wrong" are
# different facts and a shared sentence would let one read as the other:
#
#   no log file   -> the build command never ran (a missing tool, or a caller that returned early)
#   empty log     -> it ran and wrote nothing
#   log with text -> the tail, which is the failing step: _build_bundle truncates for build-image
#                    and appends for mkbundle, and _build_bundle_stamped appends for both, so the
#                    LAST lines are the last build's — never the first.

BUNDLE_LOG_TAIL="${BUNDLE_LOG_TAIL:-40}"

bundle_build_evidence() { # [log-path]
    local log="${1:-/tmp/os-fault-bundle.log}" total
    if [ ! -e "$log" ]; then
        printf '     no %s at all — the build command never ran\n' "$log"
        return 0
    fi
    if [ ! -s "$log" ]; then
        printf '     %s is empty — the build ran and wrote nothing\n' "$log"
        return 0
    fi
    total=$(wc -l <"$log" | tr -d ' ')
    printf '     --- last %s of %s lines of %s ---\n' "$BUNDLE_LOG_TAIL" "$total" "$log"
    tail -n "$BUNDLE_LOG_TAIL" "$log" | _bundle_mask | sed 's/^/     | /'
}

# The bench registry is topology and this dump is the first thing that puts build-log lines on the
# battery's STDOUT (until now they only ever reached the file). build-image.sh writes the host and
# the CA path outright — "the image will provision from $TEST_REGISTRY (TLS, CA $PITHEAD_REGISTRY_CA)"
# — and a pull failure repeats the host in every ref it names, which is exactly the tail this
# prints. Masked from the environment rather than by pattern: the value is right there, and a
# pattern for "a host:port that might be a registry" would both miss and over-match.
#
# The ref itself survives the mask, because WHICH ref failed is the diagnostic and the host is not.
# Unset variables mask nothing, so a ghcr.io build is untouched.
_bundle_mask() {
    local sed_args=()
    [ -n "${PITHEAD_REGISTRY:-}" ] && sed_args+=(-e "s|$PITHEAD_REGISTRY|<registry>|g")
    [ -n "${PITHEAD_REGISTRY_CA:-}" ] && sed_args+=(-e "s|$PITHEAD_REGISTRY_CA|<registry-ca>|g")
    [ "${#sed_args[@]}" -gt 0 ] || {
        cat
        return 0
    }
    sed "${sed_args[@]}"
}

_bundle_build_evidence_self_test() {
    local f=0 dir out
    dir=$(mktemp -d) || return 1
    out=$(bundle_build_evidence "$dir/absent.log")
    case "$out" in *'never ran'*) ;; *) f=$((f + 1)) ;; esac
    case "$out" in *empty* | *'---'*) f=$((f + 1)) ;; esac
    : >"$dir/empty.log"
    out=$(bundle_build_evidence "$dir/empty.log")
    case "$out" in *'ran and wrote nothing'*) ;; *) f=$((f + 1)) ;; esac
    case "$out" in *'never ran'* | *'---'*) f=$((f + 1)) ;; esac
    # The clip must keep the END of the log. A head would show the build's banner and hide the
    # error, which is the same nothing the row reported before.
    seq 1 100 | sed 's/^/line /' >"$dir/full.log"
    out=$(BUNDLE_LOG_TAIL=5 bundle_build_evidence "$dir/full.log")
    case "$out" in *'| line 100'*) ;; *) f=$((f + 1)) ;; esac
    case "$out" in *'line 1 '* | *'| line 1'$'\n'*) f=$((f + 1)) ;; esac
    case "$out" in *'last 5 of 100 lines'*) ;; *) f=$((f + 1)) ;; esac
    # The mask. Asserted on the RAW value being ABSENT, not on the marker being present: a mask
    # that emitted the marker while leaving the host beside it would pass a marker-only check.
    # The fixture carries a SIBLING line with no registry in it, so a mask that redacted
    # everything would also fail — narrowness needs something nearby that must survive.
    {
        printf 'the image will provision from bench.invalid:5000 (TLS, CA /srv/pki/bench-ca.crt)\n'
        printf 'Error: initializing source docker://bench.invalid:5000/pithead-dashboard:v9: no route\n'
        printf 'unrelated line naming ghcr.io/p2pool-starter-stack/pithead-dashboard:v9\n'
    } >"$dir/reg.log"
    out=$(PITHEAD_REGISTRY=bench.invalid:5000 PITHEAD_REGISTRY_CA=/srv/pki/bench-ca.crt \
        bundle_build_evidence "$dir/reg.log")
    case "$out" in *bench.invalid*) f=$((f + 1)) ;; esac
    case "$out" in */srv/pki/bench-ca.crt*) f=$((f + 1)) ;; esac
    case "$out" in *'<registry>/pithead-dashboard:v9'*) ;; *) f=$((f + 1)) ;; esac
    case "$out" in *'<registry-ca>'*) ;; *) f=$((f + 1)) ;; esac
    case "$out" in *'ghcr.io/p2pool-starter-stack/pithead-dashboard:v9'*) ;; *) f=$((f + 1)) ;; esac
    # Unset variables must mask nothing at all, or a public-registry build loses its diagnostics.
    out=$(bundle_build_evidence "$dir/reg.log")
    case "$out" in *bench.invalid:5000/pithead-dashboard:v9*) ;; *) f=$((f + 1)) ;; esac
    case "$out" in *'<registry>'*) f=$((f + 1)) ;; esac
    rm -rf "$dir"
    [ "$f" -eq 0 ] || {
        printf 'bundle-build-evidence self-test FAILED: %s checks\n' "$f"
        return 1
    }
    printf 'bundle-build-evidence self-test passed\n'
}

if [ "${BASH_SOURCE[0]}" = "${0}" ] && [ "${1:-}" = --self-test ]; then
    set -uo pipefail
    _bundle_build_evidence_self_test
fi
