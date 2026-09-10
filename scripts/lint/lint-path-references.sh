#!/usr/bin/env bash
# Fail if a repo path this tree names — in prose or in a `source` — does not resolve (#1105/#2005).
#
# A 587-file reorganization moves the targets and leaves the pointers. Sixteen comments named
# pre-move paths after the #1105 cuts, one of them in production source, and every other gate was
# green: nothing in this repo checks that a path a human typed into a comment still exists. That is
# the invariant a move breaks by construction, so it gets a gate rather than a review pass.
#
# Part 1 scans prose. Part 2 scans `source`/`.` targets, added after #2005 moved two files out from
# under references this gate could not see: the original scope excluded code on the reasoning that
# a `source` of a missing file fails loudly at run time. Both of those failed silently instead.
set -euo pipefail

# --- self-test: a path linter that finds nothing looks identical whether the tree is clean or the
# pattern stopped matching, so this proves the detector FIRES before any run is read as a pass. It
# runs the real script end to end in a throwaway repo rather than asserting on an extracted
# function — nothing here would call a function-only fix broken. Six legs: prose, then code, each
# proved to catch a dead reference and to leave a live one alone (narrowness — a linter that reds
# on everything is as useless as one that reds on nothing), and an empty enumeration is refused.
if [ "${1:-}" = "--self-test" ]; then
    tmp=$(mktemp -d)
    trap 'rm -rf "$tmp"' EXIT
    self=$(cd "$(dirname "$0")" && pwd)/$(basename "$0")
    fail=0

    leg() { # leg <name> <expect-rc> <grep-needle-or-->
        local name=$1 want=$2 needle=$3 out rc
        out=$(cd "$tmp/repo" && bash "$self" 2>&1) && rc=0 || rc=$?
        if [ "$rc" -eq "$want" ] && { [ "$needle" = "-" ] || printf '%s\n' "$out" | grep -q "$needle"; }; then
            echo "  self-test ok: $name"
        else
            echo "  self-test FAIL: $name (rc=$rc, wanted $want): $out"
            fail=1
        fi
    }

    # The fixture paths are COMPOSED, never written whole: a literal dead path in this file is a
    # dead path in a tracked file, and the scan below would (correctly) red on its own self-test.
    # Splitting the extension off keeps the fixtures realistic without arming the detector here.
    sfx=".sh"
    dead="tests/gone/vanished"
    live="tests/real/thing"

    git init -q "$tmp/repo"
    # Leg 1: a dead reference must be caught.
    mkdir -p "$tmp/repo/${live%/*}"
    echo 'x' >"$tmp/repo/$live$sfx"
    printf '# see %s for why\n' "$dead$sfx" >"$tmp/repo/probe$sfx"
    (cd "$tmp/repo" && git add -A)
    leg "a dead reference is caught" 1 "names $dead$sfx"

    # Leg 2: a live reference must NOT be caught. Same fixture, one variable moved.
    printf '# see %s for why\n' "$live$sfx" >"$tmp/repo/probe$sfx"
    (cd "$tmp/repo" && git add -A)
    leg "a live reference is NOT caught" 0 "every named repo path resolves"

    # Legs 3-4 seed the CODE scan, which the prose fixtures above cannot reach: a `source` line is
    # not prose. The fixture is a runner and the fragment it sources, because that is the shape the
    # scan is most likely to get wrong — the fragment's $HERE is the RUNNER's directory, so
    # `$HERE/<dir>/<file>` beside the runner resolves and the same expression read against the
    # fragment's own directory does not. Leg 4 asserts the CHECKED COUNT, not just rc 0: a fixture
    # whose expression silently failed to resolve would be skipped, and would pass on rc alone.
    src="source"
    here='"$HERE'
    mkdir -p "$tmp/repo/lib" "$tmp/repo/probe-bench"
    printf 'HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"\n%s %s/lib/frag%s"\n' \
        "$src" "$here" "$sfx" >"$tmp/repo/runner$sfx"
    echo ':' >"$tmp/repo/probe-bench/measure$sfx"

    # Leg 3: a dead path in CODE must be caught — the prose scan cannot see this line at all.
    printf '%s %s/probe-gone/measure%s"\n' "$src" "$here" "$sfx" >"$tmp/repo/lib/frag$sfx"
    (cd "$tmp/repo" && git add -A)
    leg "a dead code path is caught" 1 "sources probe-gone/measure$sfx"

    # Leg 4: the same fragment, repointed at the file that IS beside the runner. Resolving $HERE
    # against the fragment's own lib/ would red here, which is how every fragment in tests/
    # integration/lib and tests/os/phases would red.
    printf '%s %s/probe-bench/measure%s"\n' "$src" "$here" "$sfx" >"$tmp/repo/lib/frag$sfx"
    (cd "$tmp/repo" && git add -A)
    leg "a sourcer-relative fragment reference is NOT caught" 0 "code paths: 2 source targets"

    # Leg 5: two sources on ONE line — the shape that hid a live gap. tests/stack/test-harness-
    # tooling.sh:207 sources lib.sh and an appliance module from a single `bash -c`, and a `sed`
    # capture takes the LAST match, so the FIRST reference was never checked. The dead path here is
    # the first one deliberately; with a per-line capture this leg reads green off the second.
    printf '%s %s/probe-gone/first%s" >/dev/null; %s %s/probe-bench/measure%s"\n' \
        "$src" "$here" "$sfx" "$src" "$here" "$sfx" >"$tmp/repo/lib/frag$sfx"
    (cd "$tmp/repo" && git add -A)
    leg "the FIRST of two sources on one line is caught" 1 "sources probe-gone/first$sfx"

    # Leg 6: an empty enumeration is a broken filter, not a clean tree.
    git init -q "$tmp/empty" && mv "$tmp/repo" "$tmp/repo.bak" && mv "$tmp/empty" "$tmp/repo"
    leg "an empty enumeration is refused" 1 "returned zero files"

    [ "$fail" -eq 0 ] || {
        echo "lint-path-references self-test FAILED"
        exit 1
    }
    echo "lint-path-references self-test OK"
    exit 0
fi

# Paths that are NAMED but legitimately absent. Each needs a reason, because an entry here is the
# difference between "deliberately not on disk" and "rotted" — and only a human knows which.
allowed_absent() {
    case "$1" in
    # Generated and git-ignored; written on demand by `make test-inventory` (#414).
    docs/dev/test-inventory.md) return 0 ;;
    # Deliberately deleted, and named in the prose that explains why they went (#1105 P13).
    lib/pithead/99-remainder.sh | lib/pithead/01-prelude.sh) return 0 ;;
    # Synthetic filenames the patch-coverage self-test invents to drive its own branches.
    dashboard/mining_dashboard/web/ghost.py) return 0 ;;
    dashboard/mining_dashboard/client/tari/generated/foo_pb2.py) return 0 ;;
    # Created inside the self-test's throwaway git sandbox, never on disk here.
    tests/integration/benchmarks/bench.sh) return 0 ;;
    # A path inside the appliance BUILD CONTEXT, asserted as a string in the Dockerfile.
    os/build/stage/docker-compose.yml) return 0 ;;
    # RigForge's own repo path, vendored here under tests/integration/fakes/contract/.
    tests/contract/v1/feed.json) return 0 ;;
    *) return 1 ;;
    esac
}

# Prose-bearing tracked files. Verbatim third-party records are excluded: their paths describe
# THEIR repo, not ours, and we do not get to fix them.
files=$(git ls-files '*.sh' '*.py' '*.md' '*.yml' '*.yaml' '*.js' |
    grep -vE '^docs/research/' |
    grep -vE '(^|/)(vendor|node_modules)/' || true)

# An empty enumeration is broken, never a clean tree (same refusal as lint-docs-voice.sh, #1441).
if [ -z "$files" ]; then
    echo "path refs: the enumeration returned zero files." >&2
    echo "A broken enumeration and a clean scan both report zero hits — refusing to call either a pass." >&2
    exit 1
fi

# `json` precedes `js` so leftmost-longest matching claims `state.json` whole rather than leaving a
# phantom `state.js` behind — the difference between a real finding and a self-inflicted one.
ext='(json|yaml|yml|html|css|sh|py|js|md)'
root='(tests|lib|scripts|os|dashboard|docs|frontend)'

rc=0
for f in $files; do
    while IFS=: read -r lineno ref; do
        [ -n "${ref:-}" ] || continue
        case "$ref" in *'$'* | *'*'*) continue ;; esac
        # A pointer resolves from the repo root, from `dashboard/` (the convention inside that
        # subtree), or from any ancestor of the naming file (how `$HERE`-relative sources read).
        found=0
        for base in "" "dashboard"; do
            [ -e "${base:+$base/}$ref" ] && found=1 && break
        done
        # ...then every ancestor of the naming file, which is how a `$HERE`-relative source reads.
        d=${f%/*}
        [ "$d" = "$f" ] && d=""
        while [ "$found" = 0 ] && [ -n "$d" ]; do
            [ -e "$d/$ref" ] && found=1
            [ "$d" = "${d%/*}" ] && break
            d=${d%/*}
        done
        [ "$found" = 1 ] && continue
        allowed_absent "$ref" && continue
        echo "$f:$lineno names $ref, which does not exist" >&2
        rc=1
    done < <(grep -noE "(^|[^A-Za-z0-9/._-])$root/[A-Za-z0-9./_-]+\.$ext" "$f" 2>/dev/null |
        sed -E "s/:[^:]*[^A-Za-z0-9\/._-]($root\/)/:\1/")
done

# The code scan lives in its own file: two independent behaviours, and this one was over the
# 400-line target with it inline. It is sourced, not run, because it shares allowed_absent() and
# reports into the same $rc — and its own `source` line below is a live case for what it checks.
# shellcheck source=scripts/lint/lint-path-references-code.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lint-path-references-code.sh"

if [ "$rc" -ne 0 ]; then
    echo "" >&2
    echo "A comment naming a file that moved is worse than no comment; a source of one is a" >&2
    echo "silent no-op. Repoint it, or — if the absence is deliberate — add it to allowed_absent()" >&2
    echo "above WITH THE REASON." >&2
    exit 1
fi
echo "path references: every named repo path resolves"
echo "code paths: $code_checked source targets resolved and checked, $code_skipped expressions skipped as not statically resolvable"
