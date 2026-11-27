# shellcheck shell=bash
: "${STACK_SUITE:?is unset: this file is a tests/stack/run.sh fragment, not a script — run tests/stack/run.sh}"
# Database-copy contracts; apply transaction recovery lives in test-control-deploy.sh.
echo "== unit: carry_dashboard_data_move (#2360) =="
# Direct unit calls, mirroring mig455 above: a confirmed A-to-B dashboard.data_dir move, distinct
# from the #455 default migration — this one COPIES (never moves) and verifies by content.
carry2360() { # <workdir> <old> <new>
    (
        cd "$1" || exit 1
        # shellcheck disable=SC1090
        source "$STACK"
        set +e
        docker() { :; }
        carry_dashboard_data_move "$2" "$3"
    )
}
C="$SANDBOX/carry"
mkdir -p "$C/old" "$C/new"
printf 'livedb' >"$C/old/mining_data.db"
printf 'wal-bytes' >"$C/old/mining_data.db-wal"
printf 'journal-bytes' >"$C/old/mining_data.db-journal"
rmdir "$C/new" # an unpopulated pre-created target (ensure_directories) is not a conflict
out="$(carry2360 "$C" "$C/old" "$C/new" 2>&1)"
assert_rc "carry: succeeds" "$?" "0"
assert_eq "carry: DB copied intact" "$(cat "$C/new/mining_data.db" 2>/dev/null)" "livedb"
assert_eq "carry: -wal companion copied" "$(cat "$C/new/mining_data.db-wal" 2>/dev/null)" "wal-bytes"
assert_eq "carry: rollback journal copied" "$(cat "$C/new/mining_data.db-journal" 2>/dev/null)" "journal-bytes"
assert_eq "carry: old copy left in place (never moved)" "$(cat "$C/old/mining_data.db" 2>/dev/null)" "livedb"
# no DB at the old path: nothing live there, silent no-op.
mkdir -p "$C/empty-old" "$C/empty-new"
out="$(carry2360 "$C" "$C/empty-old" "$C/empty-new" 2>&1)"
assert_rc "carry: no DB at old path is a no-op" "$?" "0"
if [ -e "$C/empty-new/mining_data.db" ]; then bad "carry: nothing created with no source DB" "created anyway"; else ok "carry: nothing created with no source DB"; fi
# non-empty target: refuse rather than guess which DB is live; old untouched.
mkdir -p "$C/old2" "$C/occupied"
printf 'srcdb' >"$C/old2/mining_data.db"
printf 'existing' >"$C/occupied/mining_data.db"
out="$(carry2360 "$C" "$C/old2" "$C/occupied" 2>&1)"
assert_rc "carry: non-empty target refuses" "$?" "1"
assert_contains "carry: refusal names the target" "$out" "$C/occupied"
assert_eq "carry: target DB untouched by refusal" "$(cat "$C/occupied/mining_data.db")" "existing"
assert_eq "carry: source DB untouched by refusal" "$(cat "$C/old2/mining_data.db")" "srcdb"
# target nested under the live directory: refuse before a copy can be mistaken for live state.
mkdir -p "$C/old-nested/target"
printf 'nesteddb' >"$C/old-nested/mining_data.db"
out="$(carry2360 "$C" "$C/old-nested" "$C/old-nested/target" 2>&1)"
assert_rc "carry: nested target refuses" "$?" "1"
assert_eq "carry: nested refusal leaves source untouched" "$(cat "$C/old-nested/mining_data.db")" "nesteddb"
# A dashboard-writable old dir must not smuggle an otherwise allowed destination through a symlink.
mkdir -p "$C/old-escape" "$C/outside"
printf 'escapedb' >"$C/old-escape/mining_data.db"
ln -s "$C/outside" "$C/old-escape/escape"
out="$(carry2360 "$C" "$C/old-escape" "$C/old-escape/escape" 2>&1)"
assert_rc "carry: nested symlink target refuses" "$?" "1"
if [ -e "$C/outside/mining_data.db" ]; then bad "carry: symlink target untouched" "copied outside the old directory"; else ok "carry: symlink target untouched"; fi
out="$(carry2360 "$C" "$C/old-escape" "$C/old-escape/./escape" 2>&1)"
assert_rc "carry: nested symlink alias refuses" "$?" "1"
# Resolve the active path before checking its child: a symlinked current data_dir must not make
# its canonical spelling a way around the nested-target refusal.
mkdir -p "$C/old-real" "$C/outside-real"
printf 'realdb' >"$C/old-real/mining_data.db"
ln -s "$C/old-real" "$C/old-link"
ln -s "$C/outside-real" "$C/old-real/escape"
out="$(carry2360 "$C" "$C/old-link" "$C/old-real/escape" 2>&1)"
assert_rc "carry: symlinked current path refuses its canonical child" "$?" "1"
if [ -e "$C/outside-real/mining_data.db" ]; then bad "carry: canonical symlink target untouched" "copied outside the old directory"; else ok "carry: canonical symlink target untouched"; fi
# stop must succeed before copying an SQLite DB; do not snapshot a live WAL set.
mkdir -p "$C/old-stop" "$C/new-stop"
printf 'stopdb' >"$C/old-stop/mining_data.db"
out="$({
    cd "$C" || exit 1
    # shellcheck disable=SC1090
    source "$STACK"
    set +e
    docker() { return 1; }
    carry_dashboard_data_move "$C/old-stop" "$C/new-stop"
} 2>&1)"
assert_rc "carry: stop failure refuses" "$?" "1"
if [ -e "$C/new-stop/mining_data.db" ]; then bad "carry: stop failure does not copy" "copied anyway"; else ok "carry: stop failure does not copy"; fi
# corrupted/short copy: cmp catches it, refuses, source untouched (simulates a failed/partial cp).
mkdir -p "$C/old3" "$C/new3"
printf 'realdb' >"$C/old3/mining_data.db"
rmdir "$C/new3"
out="$({
    cd "$C" || exit 1
    # shellcheck disable=SC1090
    source "$STACK"
    set +e
    docker() { printf '%s\n' "$*" >"$C/dashboard-restart"; }
    cp() { : >"${*: -1}"; } # a copy that silently truncates its DEST (cp -p, so $2 is -p's src) — must be CAUGHT, not trusted
    carry_dashboard_data_move "$C/old3" "$C/new3"
} 2>&1)"
rc=$? # error() exits the subshell directly — capture ITS status, not a $? that never runs
assert_rc "carry: verifies the copy (doesn't trust cp alone)" "$rc" "1"
assert_contains "carry: restarts dashboard after a failed verify" "$(cat "$C/dashboard-restart")" "compose start dashboard"
if [ -e "$C/old3/mining_data.db" ] && [ "$(cat "$C/old3/mining_data.db")" = "realdb" ]; then
    ok "carry: source untouched after a failed verify"
else
    bad "carry: source untouched after a failed verify" "source was altered"
fi
# A successful main-DB copy is not enough: SQLite's WAL must verify too.
mkdir -p "$C/old-wal" "$C/new-wal"
printf 'waldb' >"$C/old-wal/mining_data.db"
printf 'livewal' >"$C/old-wal/mining_data.db-wal"
out="$({
    cd "$C" || exit 1
    # shellcheck disable=SC1090
    source "$STACK"
    set +e
    docker() { printf '%s\n' "$*" >"$C/dashboard-wal-restart"; }
    cp() { [ "$3" = "$C/old-wal/mining_data.db-wal" ] && : >"$4" || command cp "$@"; }
    carry_dashboard_data_move "$C/old-wal" "$C/new-wal"
} 2>&1)"
assert_rc "carry: verifies the WAL companion" "$?" "1"
assert_contains "carry: restarts dashboard after a WAL verify failure" "$(cat "$C/dashboard-wal-restart")" "compose start dashboard"
# Publishing may cross filesystems, so verify the final destination rather than trusting mv.
mkdir -p "$C/old-publish"
printf 'publishdb' >"$C/old-publish/mining_data.db"
out="$({
    cd "$C" || exit 1
    # shellcheck disable=SC1090
    source "$STACK"
    set +e
    docker() { printf '%s\n' "$*" >"$C/dashboard-publish-restart"; }
    mv() { command mv "$@" && printf 'corrupt' >"${*: -1}"; }
    carry_dashboard_data_move "$C/old-publish" "$C/new-publish"
} 2>&1)"
assert_rc "carry: verifies the published destination" "$?" "1"
assert_contains "carry: restarts dashboard after a published verify failure" "$(cat "$C/dashboard-publish-restart")" "compose start dashboard"
assert_eq "carry: publication failure leaves source intact" "$(cat "$C/old-publish/mining_data.db")" "publishdb"
if [ -n "$(ls -A "$C/new-publish")" ]; then bad "carry: publication failure cleans the partial target" "files remain"; else ok "carry: publication failure cleans the partial target"; fi
out="$(carry2360 "$C" "$C/old-publish" "$C/new-publish" 2>&1)"
assert_rc "carry: clean retry succeeds after publication failure" "$?" "0"
