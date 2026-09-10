#!/usr/bin/env bash
# Fail if a repo path named in prose — a comment, a docstring, a doc — does not resolve (#1105).
#
# A 587-file reorganization moves the targets and leaves the pointers. Sixteen comments named
# pre-move paths after the #1105 cuts, one of them in production source, and every other gate was
# green: nothing in this repo checks that a path a human typed into a comment still exists. That is
# the invariant a move breaks by construction, so it gets a gate rather than a review pass.
#
# Scope is deliberately prose, not code. A `source`/`import` of a missing file already fails loudly
# at run time; a comment pointing at a file that no longer exists fails silently, forever, and is
# read as fact by the next person.
set -euo pipefail

# --- self-test: a path linter that finds nothing looks identical whether the tree is clean or the
# pattern stopped matching, so this proves the detector FIRES before any run is read as a pass. It
# runs the real script end to end in a throwaway repo rather than asserting on an extracted
# function — nothing here would call a function-only fix broken. Three legs: it catches a dead
# reference, it does NOT catch a live one (narrowness — a linter that reds on everything is as
# useless as one that reds on nothing), and an empty enumeration is refused rather than passed.
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

    # Leg 3: an empty enumeration is a broken filter, not a clean tree.
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

if [ "$rc" -ne 0 ]; then
    echo "" >&2
    echo "A comment naming a file that moved is worse than no comment. Repoint it, or — if the" >&2
    echo "absence is deliberate — add it to allowed_absent() above WITH THE REASON." >&2
    exit 1
fi
echo "path references: every named repo path resolves"
