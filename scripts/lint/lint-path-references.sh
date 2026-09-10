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
# function — nothing here would call a function-only fix broken. Five legs: prose, then code, each
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

    # Leg 5: an empty enumeration is a broken filter, not a clean tree.
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

# ---------------------------------------------------------------------------
# Part 2: paths named in CODE, in `source`/`.` position (#2005).
#
# Part 1 is prose-only on the reasoning that a `source` of a missing file fails loudly at run
# time. #2005 disproved that twice. `. "$(cd "$(dirname "$0")/../integration" && pwd)/<probe>.sh"`
# kept a `# shellcheck source=` comment that WAS repointed, so the prose scan read green while the
# executable path still named the pre-move directory. And `REL="$ROOT/scripts/<script>.sh"` the
# prose scan cannot see at all — the `/` before `scripts` is a path character, so the word boundary
# it needs is not there — which turned every later `source "$REL" 2>/dev/null` into a silent no-op
# that surfaced ten CI files away as `not found`.
#
# Only expressions that resolve STATICALLY are checked; the rest are skipped AND COUNTED. Guessing
# at `$SANDBOX` or `$mutant` would be a false positive, and a blind spot nobody can watch growing
# is the failure this gate exists to prevent, so the skip count is printed on every run.
#
# The rule that decides the false-positive rate: a sourced fragment inherits its SOURCER's $HERE
# and $SCRIPT_DIR, not its own directory. tests/integration/lib/run-scenario.sh's
# "$HERE/benchmarks/..." is correct precisely because run.sh sourced it — resolving $HERE against
# the fragment's own lib/ reds on 7 references here, measured. Anchors therefore propagate along
# `source` edges BOTH ways (a script also inherits what the lib fragment it sources defines, which
# is how tests/stack/* get $ROOT from lib.sh), own outranks inherited, and a name arriving with two
# values is unresolvable, not guessed at.

# Its own refusal: an empty list leaves the greps below with no file arguments, reading stdin.
sh_files=$(git ls-files '*.sh')
if [ -z "$sh_files" ]; then
    echo "path refs: the shell-file enumeration returned zero files, refusing a vacuous pass." >&2
    exit 1
fi

# A `source`/`.` command word whose argument starts like a path. Requiring `"`, `$` or `/` next is
# what keeps a sentence-ending period in prose and a jq filter's `.` from parsing as a source.
src_re='(^|[^A-Za-z0-9_./"-])(source|\.)[[:space:]]+["$/]'
# An assignment that could be an anchor: built from the script's own location, from the repo root,
# or from another variable. Anything else cannot name a repo path without already being one.
asg_re='^[[:space:]]*(export +|local +)?[A-Za-z_][A-Za-z0-9_]*=("?\$\{?[A-Za-z_][A-Za-z0-9_]*\}?/|[^=]*(BASH_SOURCE|\$0|rev-parse --show-toplevel))'

# Collapse the shell idioms for "where am I" to literal segments plus `$VAR`. Run over the whole
# stream at once: a `sed` per expression costs more than the rest of this gate put together. The
# last two rules cut the expression out of its command line — after, never before, the
# `$( … && pwd)` collapse, whose body has spaces of its own.
reduce_stream() {
    sed -E \
        -e 's/["'"'"']//g' \
        -e 's/\$\(readlink [^)]*(BASH_SOURCE|\$0)[^)]*\)/@SELF@/g' \
        -e 's/\$\(dirname[^)]*(BASH_SOURCE|@SELF@|\$0)[^)]*\)/@SELFDIR@/g' \
        -e 's/\$\{BASH_SOURCE\[0\]%\/\*\}/@SELFDIR@/g' \
        -e 's/\$\{[A-Za-z_][A-Za-z0-9_]*:-([^{}]*)\}/\1/g' \
        -e 's/\$\(([A-Za-z_]+= )?cd (-[A-Za-z-]+ )*([^\&]*[^\& ]) *\&\& *pwd[^)]*\)/\3/g' \
        -e 's/\$\(git rev-parse --show-toplevel[^)]*\)/@ROOT@/g' \
        -e 's/[[:space:]].*$//' \
        -e 's/[;)}&|]+$//'
}

# asg_rows: file<TAB>line<TAB>var<TAB>reduced-rhs.  src_rows: file<TAB>line<TAB>reduced-target.
asg_raw=$(grep -nHE "$asg_re" -- $sh_files 2>/dev/null |
    sed -E 's/^([^:]+):([0-9]+):[[:space:]]*(export +|local +)?([A-Za-z_][A-Za-z0-9_]*)=/\1\t\2\t\4\t/' || true)
src_raw=$(grep -nHE "$src_re" -- $sh_files 2>/dev/null |
    grep -vE '^[^:]+:[0-9]+:[[:space:]]*#' |
    sed -E 's/^([^:]+):([0-9]+):(.*[^A-Za-z0-9_./"-])?(source|\.)[[:space:]]+/\1\t\2\t/' || true)
asg_rows=$(paste <(printf '%s' "$asg_raw" | cut -f1-3) <(printf '%s' "$asg_raw" | cut -f4- | reduce_stream))
src_rows=$(paste <(printf '%s' "$src_raw" | cut -f1-2) <(printf '%s' "$src_raw" | cut -f3- | reduce_stream))

# Bindings live in shell variables, not a table on disk: lookups run inside three nested loops, and
# a `grep` apiece put this gate's runtime in the tens of seconds. `own` outranks `inh`; a second,
# different value marks the name ambiguous, and ambiguous reads as unresolvable, never as either.
# The sentinels avoid `@`: `@unset@` beside a variable name reads as a user@host to lint-topology.
# Two files whose names mangle to one key merge their bindings, which can only widen ambiguity.
dollar='$'
tab=$(printf '\t')
bvars=""
bkey() {
    REPLY="b_${1}_${2}__${3}"
    REPLY=${REPLY//[^A-Za-z0-9_]/_}
}
bset() {
    local k cur
    bkey "$1" "$2" "$3"
    k=$REPLY
    eval "cur=\${$k-!unset!}"
    if [ "$cur" = "!unset!" ]; then
        eval "$k=\$4"
        case " $bvars " in *" $3 "*) ;; *) bvars="$bvars $3" ;; esac
    elif [ "$cur" != "$4" ]; then
        eval "$k=!amb!"
    fi
}
bget() { # bget own|any <file> <var> -> REPLY; rc 1 when unset or ambiguous
    local k cur t
    for t in own inh; do
        [ "$1" = any ] || [ "$1" = "$t" ] || continue
        bkey "$t" "$2" "$3"
        k=$REPLY
        eval "cur=\${$k-!unset!}"
        [ "$cur" = "!unset!" ] && continue
        [ "$cur" = "!amb!" ] && return 1
        REPLY=$cur
        return 0
    done
    return 1
}

norm() { # collapse . and .. -> REPLY; rc 1 if the path climbs out of the repo
    local out="" seg IFS=/
    for seg in $1; do
        case "$seg" in
        '' | .) ;;
        ..)
            [ -n "$out" ] || return 1
            case "$out" in */*) out=${out%/*} ;; *) out="" ;; esac
            ;;
        *) out="${out:+$out/}$seg" ;;
        esac
    done
    REPLY=$out
    return 0
}

resolve() { # resolve <file> <reduced-expr> -> REPLY (repo-relative); rc 1 = not statically resolvable
    local f=$1 e=$2 d v pre post
    d=${f%/*}
    [ "$d" = "$f" ] && d=""
    e=${e//@SELFDIR@/${d:-.}}
    e=${e//@ROOT@/.}
    # Substitute the ONE occurrence just parsed, by position. A replace-all of `$ROOT` would also
    # rewrite the inside of a later `$ROOTDIR`, and a corrupted path resolves to a false positive.
    for _ in 1 2 3 4; do
        case "$e" in *"$dollar"*) ;; *) break ;; esac
        pre=${e%%"$dollar"*}
        post=${e#*"$dollar"}
        post=${post#\{}
        v=${post%%[!A-Za-z0-9_]*}
        [ -n "$v" ] || return 1
        post=${post#"$v"}
        post=${post#\}}
        bget any "$f" "$v" || return 1
        e=$pre$REPLY$post
    done
    # A leftover variable, command substitution, printf placeholder, marker or glob/regex
    # metacharacter is a guess waiting to happen — tests/inventory.sh greps for its own source
    # lines with a pattern that reads just like one. No tracked path here holds any of these
    # characters, so none costs a real reference. An absolute path is not ours to check either.
    case "$e" in
    *"$dollar"* | /* | '' | *'@'* | *'`'* | *'('* | *'%'* | *'*'* | *'?'* | *'+'* | *'['* | *']'* | *'\'*) return 1 ;;
    esac
    norm "$e"
}

row3() {
    f=${1%%"$tab"*}
    REPLY=${1#*"$tab"}
    ln=${REPLY%%"$tab"*}
    expr=${REPLY#*"$tab"}
}
bind_pass() {
    local row f ln var expr
    while IFS= read -r row; do
        [ -n "$row" ] || continue
        row3 "$row"
        var=${expr%%"$tab"*}
        expr=${expr#*"$tab"}
        resolve "$f" "$expr" || continue
        bset own "$f" "$var" "${REPLY:-.}"
    done <<<"$asg_rows"
}
edge_pass() {
    local row f ln expr
    edges=""
    while IFS= read -r row; do
        [ -n "$row" ] || continue
        row3 "$row"
        resolve "$f" "$expr" || continue
        # `if`, not a trailing `&&`: an AND-list that ends false is this loop body's exit status,
        # which becomes the function's, which under `set -e` kills the run with no output at all.
        if [ -f "$REPLY" ]; then edges="$edges$f$tab$REPLY"$'\n'; fi
    done <<<"$src_rows"
}
inherit_pass() { # anchors cross a `source` edge in both directions; own always wins
    local edge a b v val
    while IFS= read -r edge; do
        [ -n "$edge" ] || continue
        a=${edge%%"$tab"*}
        b=${edge#*"$tab"}
        for v in $bvars; do
            if bget any "$a" "$v"; then
                val=$REPLY
                bget own "$b" "$v" || bset inh "$b" "$v" "$val"
            fi
            if bget any "$b" "$v"; then
                val=$REPLY
                bget own "$a" "$v" || bset inh "$a" "$v" "$val"
            fi
        done
    done <<<"$edges"
}
# Two relaxation rounds: one is not enough and three buy nothing — measured, not guessed.
# tests/stack/lifecycle/appliance-lock.sh reaches $ROOT three `source` hops from lib.sh via run.sh,
# and it is the reference round 2 recovers; the skip set is byte-identical at 2 rounds and at 12,
# where the table itself settles, and each further round costs ~4s. A deeper chain would
# under-resolve into a SKIP, never a false positive — the counter below is where that shows.
bind_pass
edge_pass
inherit_pass
bind_pass
edge_pass
inherit_pass
bind_pass

code_checked=0
code_skipped=0
while IFS= read -r row; do
    [ -n "$row" ] || continue
    row3 "$row"
    if ! resolve "$f" "$expr"; then
        code_skipped=$((code_skipped + 1))
        continue
    fi
    p=$REPLY
    # A resolved path with no directory is a repo-root name — `pithead`, which `make` generates and
    # .gitignore hides. Present or absent says nothing about a move, so it is a skip, not a pass.
    if [ "${p%%/*}" = "$p" ]; then
        code_skipped=$((code_skipped + 1))
        continue
    fi
    code_checked=$((code_checked + 1))
    [ -e "$p" ] && continue
    allowed_absent "$p" && continue
    echo "$f:$ln sources $p, which does not exist" >&2
    rc=1
done <<<"$src_rows"

if [ "$rc" -ne 0 ]; then
    echo "" >&2
    echo "A comment naming a file that moved is worse than no comment; a source of one is a" >&2
    echo "silent no-op. Repoint it, or — if the absence is deliberate — add it to allowed_absent()" >&2
    echo "above WITH THE REASON." >&2
    exit 1
fi
echo "path references: every named repo path resolves"
echo "code paths: $code_checked source targets resolved and checked, $code_skipped expressions skipped as not statically resolvable"
