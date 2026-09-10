# shellcheck shell=bash
# Part 2 of lint-path-references.sh, which sources this file and owns the verdict: `allowed_absent`
# and `rc` are the sourcer's. Split out because the two scans are independent behaviours and the
# combined file crossed the 400-line target (#1105 Phase 0) — widening the budget for a file that
# had just tripled was the wrong way to answer the gate that exists to notice exactly that.
: "${rc?is unset — this is a lint-path-references.sh fragment, not a script}"
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
# the fragment's own lib/ reds on 6 references here, measured. Anchors therefore propagate along
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
# One row per `source` on the line, not one per line: tests/stack/test-harness-tooling.sh:207 and
# :211 each source two files, and a `sed` capture takes only the LAST — the first went unchecked.
# The row keeps the whole remainder of the line; reduce_stream then collapses `$( … && pwd)` and
# truncates at the first surviving space, which lands on the right token either way.
src_raw=$(grep -nHE "$src_re" -- $sh_files 2>/dev/null | awk '
    BEGIN { OFS = "\t" }
    { i = index($0, ":"); f = substr($0, 1, i - 1); r = substr($0, i + 1)
      i = index(r, ":");  n = substr(r, 1, i - 1);  c = substr(r, i + 1)
      if (c ~ /^[ \t]*#/) next
      while (match(c, /(^|[^A-Za-z0-9_.\/"-])(source|\.)[ \t]+["$\/]/)) {
          print f, n, substr(c, RSTART + RLENGTH - 1)
          c = substr(c, RSTART + RLENGTH)
      } }' || true)
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
