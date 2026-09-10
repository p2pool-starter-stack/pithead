# shellcheck shell=bash
: "${STACK_SUITE:?source via tests/stack/run.sh}"
echo "== unit: the mutation lock serialises mutating windows (#1342) =="
# #1342: nothing in pithead excluded two mutating runs from each other, so a concurrent `backup`
# — which stops the stack — could delete a container out from under a still-running `setup`. The
# lock is scoped to mutating WINDOWS rather than whole verbs, because a wizard waiting on an
# operator (TimeoutStartSec=infinity) holding a whole-verb lock would block the boot unit forever.
# These cases prove the window refuses, names WHO holds it, gives it back, survives a
# re-invocation of pithead inside a hold, and counts nesting correctly.
LKDIR="$SANDBOX/lock"
mkdir -p "$LKDIR"
LKBIN="$SANDBOX/lockbin"
make_stubs "$LKBIN"
LKFILE="$LKDIR/explicit.lock"
LKLOG="$LKDIR/docker.log"

# Take the window in a background process and sit in it. `exec sleep` so the holder is ONE
# process: a forked sleep would inherit fd 9 and keep the lock alive past the kill below.
lock_hold_bg() { # -> sets LKHOLDER
    # Clear the record BEFORE starting, so `lock_await_record` below can only be satisfied by the
    # holder this call starts. Without it a record left by an earlier holder — a stale one is a
    # fixture in this file, and abnormal exits leave them in the field — satisfies the poll
    # instantly, the caller proceeds believing the window is held, and every case that needs
    # contention silently reports on an uncontended run instead.
    : >"$LKFILE"
    (
        cd "$LKDIR" || exit 9
        export PITHEAD_LOCK_FILE="$LKFILE"
        # shellcheck disable=SC1090
        source "$STACK"
        mutation_lock_acquire backup
        exec sleep 60
    ) >/dev/null 2>&1 &
    LKHOLDER=$!
}
# Poll for the holder record rather than sleeping a guessed interval — a sleep long enough to be
# reliable is long enough to slow the suite, and a short one is a flake waiting to happen.
lock_await_record() {
    local i=0
    while [ "$i" -lt 200 ]; do
        [ -s "$LKFILE" ] && return 0
        sleep 0.05
        i=$((i + 1))
    done
    return 1
}
# An external probe run as a CHILD opens its own descriptor, so it conflicts with a hold taken in
# any process — including this one. That is what makes it usable as a same-process probe.
lock_state() { if flock -n "$LKFILE" true 2>/dev/null; then echo free; else echo held; fi; }

lock_hold_bg
assert_rc "the holder records itself so a waiter can name it" "$(lock_await_record && echo 0 || echo 1)" "0"

: >"$LKLOG"
out="$(PITHEAD_LOCK_FILE="$LKFILE" PITHEAD_LOCK_TIMEOUT=1 DOCKER_LOG="$LKLOG" PATH="$LKBIN:$PATH" run_sourced "$LKDIR" stack_down 2>&1)"
rc=$?
assert_rc "a mutating verb refuses rather than interleaving with a held window" "$rc" "75"
# `verb=backup` is the discriminator for opening the lock file with `9>>` and not `9>`: `9>`
# truncates at OPEN time, before the flock, which would wipe the record this waiter just read.
assert_contains "the refusal names the verb holding the window" "$out" "verb=backup"
# Only that the wait is ANNOUNCED — this message is printed before the blocking flock, so it
# cannot show that any waiting happened. The release-during-wait case below proves that part.
assert_contains "the waiter announces the wait before blocking" "$out" "waiting up to 1s"
assert_contains "the refusal states that nothing was changed" "$out" "nothing was changed"
assert_eq "a refused window touches no container" "$(cat "$LKLOG")" ""

# The lock lives on the descriptor, so the kernel releases it when the holder dies — no stale
# lock file to clean up by hand, which is why `error()` (an exit) is safe inside a window.
kill "$LKHOLDER" 2>/dev/null
wait "$LKHOLDER" 2>/dev/null
: >"$LKLOG"
out="$(PITHEAD_LOCK_FILE="$LKFILE" PITHEAD_LOCK_TIMEOUT=1 DOCKER_LOG="$LKLOG" PATH="$LKBIN:$PATH" run_sourced "$LKDIR" stack_down 2>&1)"
rc=$?
assert_rc "the kernel gives the window back when the holder dies" "$rc" "0"
assert_contains "the freed window actually runs the mutation it was holding back" "$(cat "$LKLOG")" "compose down"
: >"$LKLOG"
out="$(PITHEAD_LOCK_FILE="$LKFILE" PITHEAD_LOCK_TIMEOUT=1 DOCKER_LOG="$LKLOG" PATH="$LKBIN:$PATH" run_sourced "$LKDIR" stack_down 2>&1)"
rc=$?
assert_rc "a window that completed is available to the next verb" "$rc" "0"
assert_eq "release clears the record, so nothing can name a holder that has gone" "$(cat "$LKFILE")" ""

# Arm the STALE-RECORD fixture the three cases below need, and note why they need it: with the
# lock file empty, `verb=backup` exists nowhere on disk and "never reported under the previous
# holder's name" is true of an empty string — an assertion that cannot fail for any change to
# pithead. So leave the record a real holder leaves when it is killed inside its window: the
# kernel drops the flock with the descriptor, and nothing clears the line. That is what an
# operator's Ctrl-C, and `error()` inside a window, both leave behind.
#
# The pair that discriminates is this stanza against the LIVE-holder case above: there the same
# record must be named in full (`verb=backup`), here the same bytes must not be, because the pid
# they name has gone. Suppressing every name would fail the first; echoing the file back would
# fail the second.
lock_hold_bg
lock_await_record || bad "the killed holder for the stale-record cases records itself" "no record"
kill "$LKHOLDER" 2>/dev/null
wait "$LKHOLDER" 2>/dev/null
assert_contains "a holder killed inside its window leaves its record on disk" "$(cat "$LKFILE")" "verb=backup"
assert_eq "while the kernel has already given the window itself back" "$(lock_state)" "free"

# A holder that is not pithead (an operator's own flock, a future caller) writes no record, and
# the record it finds on disk is the dead one armed above. The waiter must say so rather than
# print a stale name it happens to find.
# `flock -n FILE sleep 60 &` would NOT do: flock forks, so killing $! orphans a sleep that still
# holds the inherited descriptor for the full 60s and blocks every case after this one. Open the
# descriptor here and `exec` the sleep onto it instead, so the holder is one killable process.
(
    exec 9>>"$LKFILE"
    flock -n 9 || exit 1
    exec sleep 60
) &
LKEXT=$!
lock_held() { [ "$(lock_state)" = "held" ]; } # #1495: see wait_while_alive in lib.sh
wait_while_alive "$LKEXT" lock_held
# A poll that gives up must say so. If this one exhausts, the external holder never took the
# window: the two rc/message cases below would be reporting on an uncontended run, and the third
# passes for the worst reason available — nothing was reported under ANY name, so "never under
# the previous holder's name" is true of an empty string.
if [ "$(lock_state)" != "held" ]; then
    bad "the unrecorded holder takes the window" "the lock is free, so the three cases below prove nothing"
fi
out="$(PITHEAD_LOCK_FILE="$LKFILE" PITHEAD_LOCK_TIMEOUT=1 DOCKER_LOG="$LKLOG" PATH="$LKBIN:$PATH" run_sourced "$LKDIR" stack_down 2>&1)"
rc=$?
assert_rc "an unrecorded holder still blocks the window" "$rc" "75"
assert_contains "an unrecorded holder is reported as unrecorded" "$out" "holder unrecorded"
assert_not_contains "and is never reported under the previous holder's name" "$out" "verb=backup"
kill "$LKEXT" 2>/dev/null
wait "$LKEXT" 2>/dev/null

# A blocked waiter must actually WAIT and then proceed — not print that it is waiting and refuse.
# Driven by releasing the lock underneath a waiter that is already blocked, rather than by timing:
# start the waiter, poll until it has announced the wait, then kill the holder and read its result.
# The pair is what discriminates. "Announced the wait" alone would also be true of a build that
# refuses on contact; rc=0 alone would also be true of a lock that was never taken.
: >"$LKLOG"
LKWOUT="$LKDIR/waiter.out"
: >"$LKWOUT"
lock_hold_bg
lock_await_record || bad "the holder for the release-during-wait case records itself" "no record"
(
    PITHEAD_LOCK_FILE="$LKFILE" PITHEAD_LOCK_TIMEOUT=30 DOCKER_LOG="$LKLOG" PATH="$LKBIN:$PATH" run_sourced "$LKDIR" stack_down >"$LKWOUT" 2>&1
    echo "rc=$?" >>"$LKWOUT"
) &
LKWAITER=$!
i=0
while [ "$i" -lt 200 ]; do
    grep -q "waiting up to" "$LKWOUT" 2>/dev/null && break
    sleep 0.05
    i=$((i + 1))
done
# Same shape. If the waiter never announced, the kill below frees the window before anything was
# blocked on it, and the three cases become a report on a verb that never contended at all.
if ! grep -q "waiting up to" "$LKWOUT" 2>/dev/null; then
    bad "the waiter reaches the held window before the holder is killed" "no announcement, so the three cases below prove nothing"
fi
kill "$LKHOLDER" 2>/dev/null
wait "$LKHOLDER" 2>/dev/null
wait "$LKWAITER" 2>/dev/null
assert_contains "a contending verb blocks rather than refusing on contact" "$(cat "$LKWOUT")" "waiting up to"
assert_contains "and proceeds once the holder leaves, instead of timing out" "$(cat "$LKWOUT")" "rc=0"
assert_contains "the mutation it was waiting to make then actually runs" "$(cat "$LKLOG")" "compose down"

# The re-invocation pair. pithead re-invokes ITSELF for mutating verbs (run_chain,
# control_lifecycle's `"$self" restart`, control_backup's `"$self" backup -y`), so a lock that
# only knew about descriptors would deadlock a parent against its own child — IF any of those
# three ever ran inside a window an ancestor already held. #1391's own census of every
# mutation_lock_acquire call site found that none currently does; the marker is defensive, not
# load-bearing today. fd 9
# is inherited across exec, but a child that opens its OWN descriptor on the same file blocks —
# which is why the marker is EXPORTED rather than merely set. Stripping the marker is therefore
# the mutation that proves the marker is what carries the hold across the re-invocation.
lock_reinvoke_probe() { # <1=keep the inherited marker|0=strip it> -> "<child rc>|<docker>|<parent>"
    local keep="$1" clog="$LKDIR/child.log"
    : >"$clog"
    (
        cd "$LKDIR" || exit 9
        export PITHEAD_LOCK_FILE="$LKFILE" PITHEAD_LOCK_TIMEOUT=1
        export PATH="$LKBIN:$PATH" DOCKER_LOG="$clog"
        # shellcheck disable=SC1090
        source "$STACK"
        # pithead:14 is `set -Eeuo pipefail`, and sourcing it turns errexit on HERE — which would
        # kill this subshell at the deliberately-failing child below. run_sourced does the same.
        set +e
        mutation_lock_acquire backup
        local crc st=free called=untouched
        # Take the child's exit status from the child itself, not from an `echo "$?"` inside it:
        # the refusal path is error(), which exits, so any trailing echo never runs and would
        # report an empty status for the very case this asserts.
        case "$keep" in
        1) bash -c 'source "$1"; stack_down' _ "$STACK" >/dev/null 2>&1 ;;
        0) env -u PITHEAD_LOCK_HELD bash -c 'source "$1"; stack_down' _ "$STACK" >/dev/null 2>&1 ;;
        # Two sequential windows in one re-invoked child. This is what the not-owner guard in
        # mutation_lock_release is for: without it the FIRST release closes the inherited
        # descriptor and drops the marker, so the child's SECOND window opens a descriptor of its
        # own and deadlocks against the parent that invoked it.
        2) bash -c 'source "$1"; set +e
               mutation_lock_acquire down && mutation_lock_release
               mutation_lock_acquire down && mutation_lock_release' _ "$STACK" >/dev/null 2>&1 ;;
        esac
        crc=$?
        flock -n "$LKFILE" true 2>/dev/null || st=held
        [ -s "$clog" ] && called=called
        # An inherited hold belongs to the ancestor, so the child's release must leave the record
        # alone. Clearing it would leave the parent holding a window that the next waiter can only
        # describe as "unrecorded" — the lock still correct, the diagnosis silently lost.
        local rec recstate=other
        rec=$(head -n 1 "$LKFILE" 2>/dev/null)
        case "$rec" in
        *verb=backup*) recstate=intact ;;
        "") recstate=cleared ;;
        esac
        printf '%s|%s|%s|%s\n' "$crc" "$called" "$st" "$recstate"
    ) 2>/dev/null
}
assert_eq "a re-invoked pithead inside a held window proceeds on the inherited marker" \
    "$(lock_reinvoke_probe 1)" "0|called|held|intact"
assert_eq "without the marker that same child blocks on its own parent and changes nothing" \
    "$(lock_reinvoke_probe 0)" "75|untouched|held|intact"
assert_eq "a re-invoked child can open a second window without deadlocking on its parent" \
    "$(lock_reinvoke_probe 2)" "0|untouched|held|intact"

# Nesting: an inner window (backup -> down) must not hand the lock back when IT finishes, only
# when the outermost one does. This is what the depth counter is for; without it the first
# release inside a backup would free the stack mid-archive.
lock_nest_probe() { # <releases> -> free|held
    (
        cd "$LKDIR" || exit 9
        export PITHEAD_LOCK_FILE="$LKFILE"
        # shellcheck disable=SC1090
        source "$STACK"
        set +e # sourcing pithead turns errexit on here (pithead:14)
        mutation_lock_acquire backup
        mutation_lock_acquire down
        local i=0
        while [ "$i" -lt "$1" ]; do
            mutation_lock_release
            i=$((i + 1))
        done
        if flock -n "$LKFILE" true 2>/dev/null; then echo free; else echo held; fi
    ) 2>/dev/null
}
assert_eq "an inner window closing does not release the outer one" "$(lock_nest_probe 1)" "held"
assert_eq "the outermost release is the one that gives the lock back" "$(lock_nest_probe 2)" "free"

# A bad argument must be rejected AT ONCE, not after waiting out someone else's window. Validating
# inside the hold made `restart typo` sit for PITHEAD_LOCK_TIMEOUT seconds only to report a typo.
lock_hold_bg
assert_rc "the holder for the restart cases records itself" "$(lock_await_record && echo 0 || echo 1)" "0"
: >"$LKLOG"
out="$(PITHEAD_LOCK_FILE="$LKFILE" PITHEAD_LOCK_TIMEOUT=1 DOCKER_LOG="$LKLOG" PATH="$LKBIN:$PATH" run_sourced "$LKDIR" stack_restart bogus 2>&1)"
rc=$?
assert_rc "a bad restart argument is still rejected while the lock is held" "$rc" "1"
assert_contains "the rejection names the contract" "$out" "takes no argument, 'tor'"
assert_not_contains "a bad argument never waits out another operation's window" "$out" "waiting up to"
assert_eq "and it touches no container" "$(cat "$LKLOG")" ""
# Control for the assertion above: without this, "no waiting message" would also be true of a lock
# that was never held, and the case would pass for a reason unrelated to the guard.
out="$(PITHEAD_LOCK_FILE="$LKFILE" PITHEAD_LOCK_TIMEOUT=1 DOCKER_LOG="$LKLOG" PATH="$LKBIN:$PATH" run_sourced "$LKDIR" stack_restart 2>&1)"
assert_contains "while a VALID restart against the same held window does wait" "$out" "waiting up to"
kill "$LKHOLDER" 2>/dev/null
wait "$LKHOLDER" 2>/dev/null

# The shipped default: no PITHEAD_LOCK_FILE, so the lock is .pithead.lock in the stack directory
# (pithead cd's to its own directory when executed, so that path is stable across invocations).
rm -f "$LKDIR/.pithead.lock"
DOCKER_LOG="$LKLOG" PATH="$LKBIN:$PATH" run_sourced "$LKDIR" stack_down >/dev/null 2>&1
assert_eq "the lock defaults to .pithead.lock in the stack directory" \
    "$([ -f "$LKDIR/.pithead.lock" ] && echo present || echo absent)" "present"

# An unopenable lock file degrades OPEN, exactly like a missing flock and for the same reason: a
# deploy root only root can write, or a read-only mount, is an environment fault, and refusing
# every mutating verb on such a box is a worse regression than the race. The path here has a
# REGULAR FILE as its parent, so the open fails with ENOTDIR for any uid — a chmod-based fixture
# would silently stop being a fixture under a root-run suite and the case would pass vacuously.
printf 'not a directory\n' >"$LKDIR/notadir"
: >"$LKLOG"
out="$(PITHEAD_LOCK_FILE="$LKDIR/notadir/nope.lock" DOCKER_LOG="$LKLOG" PATH="$LKBIN:$PATH" run_sourced "$LKDIR" stack_down 2>&1)"
rc=$?
assert_rc "an unopenable lock file degrades instead of refusing every mutating verb" "$rc" "0"
assert_contains "and says out loud that it is no longer serialising anything" "$out" "cannot serialise itself"
assert_contains "the mutation it could not serialise still runs" "$(cat "$LKLOG")" "compose down"

# The lock is keyed on the DEPLOY ROOT, not on the directory pithead was run from. One stack is
# several sibling pithead-vX.Y.Z dirs (`current ->`, the rollback copy, and the fresh dir the
# dashboard's one-click upgrade creates and runs `./pithead upgrade` inside), all driving the same
# Compose project against the same data. Keyed on the directory, that upgrade and a concurrent
# `backup` took different lock files and could not see each other — uncontended by construction,
# which is #1059 wearing a green tick.
LKROOT="$SANDBOX/deploy"
mkdir -p "$LKROOT/pithead-v1.0.0" "$LKROOT/pithead-v2.0.0" "$LKROOT/plain-a" "$LKROOT/plain-b"
# Hold a window in one dir; drive a mutating verb from its sibling. `env -u PITHEAD_LOCK_HELD`
# because the concurrent actor is a SEPARATE process tree — inheriting the marker would make the
# child skip the lock entirely and the case would pass without ever contending.
lock_sibling_probe() { # <holder dir> <other dir> -> "<rc>|<mutated?>"
    local clog="$LKROOT/sib.log"
    : >"$clog"
    (
        cd "$1" || exit 9
        # shellcheck disable=SC1090
        source "$STACK"
        set +e # sourcing pithead turns errexit on here (pithead:14)
        mutation_lock_acquire backup
        PITHEAD_LOCK_TIMEOUT=1 DOCKER_LOG="$clog" PATH="$LKBIN:$PATH" \
            env -u PITHEAD_LOCK_HELD bash -c 'cd "$2" || exit 9; source "$1"; set +e; stack_down' _ "$STACK" "$2" >/dev/null 2>&1
        local rc=$? mutated=untouched
        grep -q 'compose down' "$clog" 2>/dev/null && mutated=mutated
        printf '%s|%s\n' "$rc" "$mutated"
    ) 2>/dev/null
}
assert_eq "a window held in one version dir blocks its sibling, which is where the one-click upgrade runs" \
    "$(lock_sibling_probe "$LKROOT/pithead-v1.0.0" "$LKROOT/pithead-v2.0.0")" "75|untouched"
# The control that makes the case above mean something: two dirs that are NOT a versioned deploy
# keep their own locks, so the block is the deploy root talking and not merely "two directories".
assert_eq "two unrelated stacks still lock independently" \
    "$(lock_sibling_probe "$LKROOT/plain-a" "$LKROOT/plain-b")" "0|mutated"
rm -f "$LKROOT/.pithead.lock" "$LKROOT/pithead-v1.0.0/.pithead.lock"
DOCKER_LOG="$LKLOG" PATH="$LKBIN:$PATH" run_sourced "$LKROOT/pithead-v1.0.0" stack_down >/dev/null 2>&1
assert_eq "a versioned install keys its lock on the deploy root its siblings share" \
    "$([ -f "$LKROOT/.pithead.lock" ] && echo present || echo absent)" "present"
assert_eq "and leaves no second, uncontendable lock inside the version dir" \
    "$([ -f "$LKROOT/pithead-v1.0.0/.pithead.lock" ] && echo present || echo absent)" "absent"
