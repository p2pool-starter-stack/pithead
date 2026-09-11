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
#
# NO REGEX, and no `sed`. The needle is a literal that arrives from the environment, and putting it
# in a `s|…|…|` expression made the value's own characters part of the program. Measured, not
# feared: a `|` ended the substitution early, sed exited with "bad flag in substitute command" and
# the WHOLE TAIL was dropped — a header with nothing under it, evidence turned back into the
# silence this file exists to remove. A `\` or a `[` was worse because it was quiet: `reg[1]:5000`
# is a character class matching `reg1:5000`, so the mask missed the literal and the raw host went
# out masked-looking but intact. Bash's `${var//"$needle"/…}` takes the needle literally when the
# pattern is quoted (true back to bash 3.2, which is what macOS still ships), so no character in
# the value can change what the replacement does.
_bundle_mask() {
    local line
    while IFS= read -r line || [ -n "$line" ]; do
        [ -z "${PITHEAD_REGISTRY:-}" ] || line=${line//"$PITHEAD_REGISTRY"/'<registry>'}
        [ -z "${PITHEAD_REGISTRY_CA:-}" ] || line=${line//"$PITHEAD_REGISTRY_CA"/'<registry-ca>'}
        printf '%s\n' "$line"
    done
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
    # HOSTILE VALUES. A control that only ever sees `bench.invalid:5000` is green by construction
    # against the defect class that actually bit: the needle comes from the environment, and under
    # `sed` its own characters became part of the program. `|` dropped the entire tail; `\` and `[`
    # leaked the raw host while still looking masked. Each value is asserted four ways, because any
    # one alone can be satisfied by a broken mask — no leak, no lost tail, the mask present, and a
    # sibling line with no registry in it still there so a mask that ate everything fails too.
    local reg
    for reg in 'bench.invalid:5000' 'a|b:5000' 'a&b:5000' 'a\b:5000' 'reg[1]:5000' 'r*g:5000' \
        'reg?:5000' 'a b:5000' 'a.c:5000'; do
        {
            printf 'pull failed: %s/pithead-dashboard:v9\n' "$reg"
            printf 'unrelated ghcr.io/p2pool-starter-stack line\n'
        } >"$dir/hostile.log"
        out=$(PITHEAD_REGISTRY="$reg" bundle_build_evidence "$dir/hostile.log")
        case "$out" in *"$reg"*) f=$((f + 1)) ;; esac                                    # the raw value leaked
        case "$out" in *'<registry>/pithead-dashboard:v9'*) ;; *) f=$((f + 1)) ;; esac   # masked, ref kept
        case "$out" in *'ghcr.io/p2pool-starter-stack line'*) ;; *) f=$((f + 1)) ;; esac # sibling survived
        case "$out" in *'--- last '*) ;; *) f=$((f + 1)) ;; esac                         # the tail is still there
    done
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
