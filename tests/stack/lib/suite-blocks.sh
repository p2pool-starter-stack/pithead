# shellcheck shell=bash
# run.sh's blocks (#2631): the source order cut into contiguous `if in_block K; then ... fi` groups,
# one per Shell-workflow matrix leg. Checked before any block runs, because each way this goes wrong
# is silent: a stanza outside every block runs in none of the legs (or, as inline code, in all of
# them), a stanza in two blocks runs twice, and a leg the matrix never starts reports nothing.
# Prints one line per defect and returns 1 when there is any.
stack_blocks_audit() { # <run.sh> <workflow.yml> [suite-directory]
    local runsh="$1" wf="$2" n want have defects expected suite="${3:-${1%/*}}"
    n=$(sed -n 's/^STACK_BLOCKS=\([1-9][0-9]*\)$/\1/p' "$runsh")
    [ -n "$n" ] || {
        echo "$runsh declares no STACK_BLOCKS=<n>"
        return 1
    }
    want=$(seq -s, 1 "$n")
    have=$(sed -n 's/^ *block: \[\([0-9, ]*\)\].*$/\1/p' "$wf" | tr -d ' ')
    expected=$(find "$suite" -type f -name 'test*.sh' ! -path '*/standalone/*' | sed "s|^$suite/||" | sort) || return 1
    defects=$(
        [ "$have" = "$want" ] || echo "$wf matrix lists blocks [$have], run.sh declares [$want]"
        awk -v n="$n" -v expected="$expected" '
            BEGIN { count = split(expected, files, "\n"); for (k = 1; k <= count; k++) if (files[k] != "") want[files[k]] = 1 }
            /^[[:space:]]*#/ { next }
            /^if in_block [0-9]+; then$/ {
                b = $3 + 0
                if (open) print "block " b " opens inside block " open
                if (b != ++seen) print "block " b " is out of order: expected block " seen
                open = b
                next
            }
            open && /^fi$/ { open = 0; next }
            match($0, /(source|bash) "\$HERE\/[^"]+"/) {
                call = substr($0, RSTART, RLENGTH)
                split(call, quoted, "\"")
                f = substr(quoted[2], 7)
                if (f !~ /(^|\/)test[^\/]*\.sh$/) next
                if (!open) print f " is sourced outside every block"
                else if (f in at) print f " is sourced in block " at[f] " and block " open
                else at[f] = open
            }
            !open && /^[[:space:]]*(assert_[a-z_]+|ok|bad) / { print "line " NR " asserts outside every block" }
            END {
                for (f in want) if (!(f in at)) print f " is absent from every block"
                for (f in at) if (!(f in want)) print f " is not a suite file on disk"
                if (open) print "block " open " is never closed"
                if (seen != n) print "run.sh opens " seen " blocks, STACK_BLOCKS says " n
            }' "$runsh"
    )
    [ -z "$defects" ] && return 0
    printf '%s\n' "$defects"
    return 1
}

# Sum a full run's per-block tallies ("<block> <pass> <fail>" lines). A block with no line died
# before its verdict — an `exit` in a fragment, a refused mk_tmpdir — and counts as one failure,
# never as a block that contributed nothing.
stack_blocks_sum() { # <tally-file> <blocks> -> "<pass> <fail>"
    awk -v n="$2" '
        { p[$1] = $2; f[$1] = $3 }
        END {
            for (k = 1; k <= n; k++) {
                if (k in p) { P += p[k]; F += f[k] }
                else { print "block " k " ended without a verdict" > "/dev/stderr"; F++ }
            }
            print P + 0, F + 0
        }' "$1"
}
