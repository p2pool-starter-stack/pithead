#!/usr/bin/env bash
set -Eeuo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
: "${TMPDIR:=/tmp}"
T=$(mktemp -d "$TMPDIR/migration-boot.XXXXXX")
trap 'rm -rf "$T"' EXIT

fail() {
    printf 'selftest-migration-boot: FAIL: %s\n' "$*" >&2
    exit 1
}

assert_file() {
    local path="$1" expected="$2" actual
    [ -f "$path" ] || fail "$path is absent"
    actual=$(tr -d ' \t\r\n' <"$path")
    [ "$actual" = "$expected" ] || fail "$path: expected [$expected], got [$actual]"
}

assert_absent() { [ ! -e "$1" ] || fail "$1 is present"; }

assert_call() { grep -Fqx "$2" "$1/calls" || fail "$1 missing call: $2"; }

assert_no_call() { ! grep -Fq "$2" "$1/calls" || fail "$1 has unexpected call: $2"; }

assert_order() {
    local dir="$1" first="$2" second="$3" a b
    a=$(grep -n -m1 -Fx "$first" "$dir/calls" | cut -d: -f1)
    b=$(grep -n -m1 -Fx "$second" "$dir/calls" | cut -d: -f1)
    [ -n "$a" ] && [ -n "$b" ] && [ "$a" -lt "$b" ] || fail "$first did not precede $second"
}

assert_later() {
    local dir="$1" first="$2" second="$3" line rest
    line=$(grep -n -m1 -Fx "$first" "$dir/calls" | cut -d: -f1)
    [ -n "$line" ] || fail "$dir missing call: $first"
    rest=$(tail -n "+$((line + 1))" "$dir/calls")
    grep -Fqx "$second" <<<"$rest" || fail "$second did not follow $first"
}

assert_later_contains() {
    local dir="$1" first="$2" second="$3" line rest
    line=$(grep -n -m1 -Fx "$first" "$dir/calls" | cut -d: -f1)
    [ -n "$line" ] || fail "$dir missing call: $first"
    rest=$(tail -n "+$((line + 1))" "$dir/calls")
    grep -Fq "$second" <<<"$rest" || fail "$second did not follow $first"
}

wait_file() {
    local path="$1" tries="${2:-500}"
    while [ "$tries" -gt 0 ]; do
        [ -e "$path" ] && return 0
        sleep 0.01
        tries=$((tries - 1))
    done
    return 1
}

mkdir -p "$T/bin"
cat >"$T/bin/rauc" <<'EOF'
#!/usr/bin/env bash
printf 'rauc %s\n' "$*" >>"${CALLS:?}"
case "$*" in
'status --output-format=json')
    slot="${RAUC_BOOT_SLOT:-A}"
    printf '{"booted":"%s","slots":[{"rootfs.0":{"bootname":"%s","state":"booted","boot_status":"good"}}]}\n' "$slot" "$slot"
    ;;
'status mark-good') exit "${RAUC_MARK_GOOD_RC:-0}" ;;
'status mark-bad other') exit "${RAUC_MARK_BAD_RC:-0}" ;;
*) exit 91 ;;
esac
EOF
cat >"$T/bin/sync" <<'EOF'
#!/usr/bin/env bash
printf 'sync %s\n' "$*" >>"${CALLS:?}"
last=$(grep '^rauc ' "${CALLS:?}" | tail -1)
[ "${SYNC_FAIL_COMMIT:-0}" != 1 ] || [ "$last" != 'rauc status mark-good' ] || exit 1
case "$*" in
-f*/.os-data-floor.*) [ "${SYNC_FAIL_FLOOR:-0}" != 1 ] || exit 1 ;;
esac
EOF
cat >"$T/bin/stat" <<'EOF'
#!/usr/bin/env bash
if [ "$(uname -s)" = Darwin ] && [ "$1" = -Lc ]; then
    shift 2
    exec /usr/bin/stat -f '%d:%i:%m:%c' "$1"
fi
exec /usr/bin/stat "$@"
EOF
chmod +x "$T/bin/rauc" "$T/bin/sync" "$T/bin/stat"

new_fixture() {
    local dir="$T/$1"
    mkdir -p "$dir"
    cp "$ROOT/pithead" "$dir/pithead.real"
    printf '%s\n' "$2" >"$dir/VERSION"
    printf 'quiet rauc.slot=%s\n' "$3" >"$dir/cmdline"
    printf '%s\n' "$4" >"$dir/.os-migration-pending"
    printf '2.0.0\n' >"$dir/.os-data-floor"
    printf '1.5.0\n' >"$dir/.os-data-floor.prev"
    : >"$dir/calls"
    cat >"$dir/pithead" <<'EOF'
#!/usr/bin/env bash
if [ "${BASH_SOURCE[0]}" != "$0" ]; then
    source "${REAL_CLI:?}"
    return
fi
printf 'pithead %s\n' "$*" >>"${CALLS:?}"
EOF
    chmod +x "$dir/pithead"
    printf '%s' "$dir"
}

fixture_env() {
    export PATH="$T/bin:$PATH" REAL_CLI="$1/pithead.real" CALLS="$1/calls"
    export PITHEAD_CMDLINE="$1/cmdline" PITHEAD_DATA_FLOOR_FILE="$1/.os-data-floor"
    export PITHEAD_MIGRATION_MARKER_FILE="$1/.os-migration-pending"
    export PITHEAD_LOCK_FILE="$1/lock"
    export RAUC_BOOT_SLOT="$2" RAUC_MARK_GOOD_RC=0 RAUC_MARK_BAD_RC=0
    export SYNC_FAIL_COMMIT=0 SYNC_FAIL_FLOOR=0
}

ownership_case() (
    local dir="$1" slot="$2" block
    cd "$dir" || exit 99
    fixture_env "$dir" "$slot"
    # shellcheck source=/dev/null
    source "$ROOT/os/overlay/pithead-boot"
    fail_boot() {
        printf 'fail %s\n' "$*" >>"$dir/calls"
        exit 1
    }
    block=$(sed -n '/^hold_chain=0$/,/^esac$/p' "$ROOT/os/overlay/pithead-boot")
    eval "$block"
    printf '%s\n' "$hold_chain" >"$dir/hold"
)

A_OTHER=$(new_fixture a-other 1.5.0 A '2.0.0|B')
ownership_case "$A_OTHER" A || fail 'source A rejected the eligible B candidate'
assert_file "$A_OTHER/hold" 0
assert_file "$A_OTHER/.os-migration-pending" '2.0.0|B'
assert_file "$A_OTHER/.os-data-floor" 2.0.0

A_WRONG=$(new_fixture a-wrong-version 1.5.0 A '2.0.0|A')
set +e
ownership_case "$A_WRONG" A
rc=$?
set -e
[ "$rc" -eq 1 ] || fail "same-slot different-version ownership returned $rc"
assert_call "$A_WRONG" 'fail the migration marker could not be assigned to the booted slot'
assert_file "$A_WRONG/.os-migration-pending" '2.0.0|A'

B_OWNER=$(new_fixture b-owner 2.0.0 B '2.0.0|B')
ownership_case "$B_OWNER" B >/dev/null 2>&1 || fail 'candidate B did not take its migration hold'
assert_file "$B_OWNER/hold" 1

gate_case() (
    local dir="$1" slot="$2" hold="$3" gate_loop
    cd "$dir" || exit 99
    fixture_env "$dir" "$slot"
    export RAUC_MARK_GOOD_RC="${CASE_MARK_GOOD_RC:-0}"
    export RAUC_MARK_BAD_RC="${CASE_MARK_BAD_RC:-0}"
    export SYNC_FAIL_COMMIT="${CASE_SYNC_FAIL_COMMIT:-0}"
    export SYNC_FAIL_FLOOR="${CASE_SYNC_FAIL_FLOOR:-0}"
    # shellcheck source=/dev/null
    source "$dir/pithead"
    # shellcheck disable=SC2034 # read by the extracted production loop
    migration_fingerprint=$(os_migration_fingerprint)
    # shellcheck source=/dev/null
    PITHEAD_RELEASE_UP_TRIES=1 PITHEAD_RELEASE_UP_PAUSE=0 source "$ROOT/os/overlay/pithead-boot"
    # shellcheck disable=SC2034 # read by the extracted production loop
    gate_doctor_ran=0 gate_advisory="" hold_chain="$hold" OS_INFLIGHT="$dir/absent"
    # shellcheck disable=SC2034 # read by the extracted production loop
    gate_target=fixture gate_resolve_args=()
    gate_probe_header() { :; }
    curl() { printf '200 1\n'; }
    gate_ready() { return 0; }
    fail_boot() {
        printf 'fail %s\n' "$*" >>"$dir/calls"
        exit 1
    }
    boot_gate_passed() { printf 'gate-passed\n' >>"$dir/calls"; }
    timeout() { printf 'timeout %s\n' "$*" >>"$dir/calls"; }
    gate_loop=$(sed -n '/^gate_wait_started=/,/^done$/p' "$ROOT/os/overlay/pithead-boot")
    eval "$gate_loop"
)

for failure in mark sync; do
    D=$(new_fixture "commit-$failure" 1.5.0 A '2.0.0|B')
    set +e
    if [ "$failure" = mark ]; then
        CASE_MARK_GOOD_RC=1 gate_case "$D" A 0 >"$D/out" 2>&1
    else
        CASE_SYNC_FAIL_COMMIT=1 gate_case "$D" A 0 >"$D/out" 2>&1
    fi
    rc=$?
    set -e
    [ "$rc" -eq 1 ] || fail "$failure commit failure returned $rc"
    assert_file "$D/.os-migration-pending" '2.0.0|B'
    assert_file "$D/.os-data-floor.prev" 1.5.0
    assert_no_call "$D" 'mark-bad other'
done

HELD_FAIL=$(new_fixture held-commit-fail 2.0.0 B '2.0.0|B')
set +e
CASE_MARK_GOOD_RC=1 gate_case "$HELD_FAIL" B 1 >"$HELD_FAIL/out" 2>&1
rc=$?
set -e
[ "$rc" -eq 1 ] || fail "held candidate commit failure returned $rc"
assert_file "$HELD_FAIL/.os-migration-pending" '2.0.0|B'
assert_file "$HELD_FAIL/.os-data-floor.prev" 1.5.0
assert_no_call "$HELD_FAIL" 'pithead up'

FALLBACK=$(new_fixture fallback-success 1.5.0 A '2.0.0|B')
gate_case "$FALLBACK" A 0 >"$FALLBACK/out" 2>&1 || fail 'committed fallback reconciliation failed'
assert_file "$FALLBACK/.os-data-floor" 1.5.0
assert_absent "$FALLBACK/.os-data-floor.prev"
assert_absent "$FALLBACK/.os-migration-pending"
assert_order "$FALLBACK" 'rauc status mark-good' 'sync '
assert_order "$FALLBACK" 'sync ' 'rauc status mark-bad other'
assert_later "$FALLBACK" 'rauc status mark-bad other' 'sync '
assert_later_contains "$FALLBACK" 'rauc status mark-bad other' 'sync -f '

EMPTY=$(new_fixture empty-snapshot 1.5.0 A '2.0.0|B')
set +e
(
    cd "$EMPTY" || exit 99
    fixture_env "$EMPTY" A
    # shellcheck source=/dev/null
    source "$ROOT/os/overlay/pithead-boot"
    clear_migration_hold ''
)
rc=$?
set -e
[ "$rc" -eq 3 ] || fail "empty clear snapshot returned $rc instead of a stale-snapshot skip"
assert_file "$EMPTY/.os-migration-pending" '2.0.0|B'
assert_file "$EMPTY/.os-data-floor.prev" 1.5.0
assert_no_call "$EMPTY" 'mark-bad other'

RESTORE_FAIL=$(new_fixture fallback-restore-fail 1.5.0 A '2.0.0|B')
CASE_SYNC_FAIL_FLOOR=1 gate_case "$RESTORE_FAIL" A 0 >"$RESTORE_FAIL/out" 2>&1 ||
    fail 'a committed boot failed because fallback cleanup failed'
assert_file "$RESTORE_FAIL/.os-data-floor" 2.0.0
assert_file "$RESTORE_FAIL/.os-data-floor.prev" 1.5.0
assert_file "$RESTORE_FAIL/.os-migration-pending" '2.0.0|B'
grep -Fq 'FAULT — the previous migration candidate remains protected' "$RESTORE_FAIL/out" ||
    fail 'fallback cleanup failure was not reported'

RELEASE=$(new_fixture candidate-release 2.0.0 B '2.0.0|B')
gate_case "$RELEASE" B 1 >"$RELEASE/out" 2>&1 || fail 'candidate commit and release failed'
assert_absent "$RELEASE/.os-data-floor.prev"
assert_absent "$RELEASE/.os-migration-pending"
assert_call "$RELEASE" 'pithead up'

if [ "$(uname -s)" = Linux ]; then
    RACE=$(new_fixture cleanup-race 1.5.0 A '2.0.0|B')
    OLD_FINGERPRINT=$(
        cd "$RACE" || exit 99
        fixture_env "$RACE" A
        # shellcheck source=/dev/null
        source "$RACE/pithead"
        os_migration_fingerprint
    )
    (
        cd "$RACE" || exit 99
        fixture_env "$RACE" A
        # shellcheck source=/dev/null
        source "$RACE/pithead"
        exec 8>"$PITHEAD_LOCK_FILE"
        flock 8
        : >holder-ready
        wait_file replace
        os_raise_data_floor 2.0.0 '2.0.0|B'
        : >replaced
        wait_file release
    ) &
    HOLDER_PID=$!
    if ! wait_file "$RACE/holder-ready"; then
        kill "$HOLDER_PID" 2>/dev/null || true
        wait "$HOLDER_PID" 2>/dev/null || true
        fail 'the exact lock holder did not start'
    fi
    (
        cd "$RACE" || exit 99
        fixture_env "$RACE" A
        # shellcheck source=/dev/null
        source "$ROOT/os/overlay/pithead-boot"
        : >cleanup-started
        restore_data_floor_after_fallback "$OLD_FINGERPRINT"
        : >cleanup-done
    ) >"$RACE/cleanup.out" 2>&1 &
    CLEANUP_PID=$!
    if ! wait_file "$RACE/cleanup-started"; then
        : >"$RACE/release"
        wait "$HOLDER_PID" 2>/dev/null || true
        kill "$CLEANUP_PID" 2>/dev/null || true
        wait "$CLEANUP_PID" 2>/dev/null || true
        fail 'the exact cleanup child did not start'
    fi
    WAITED=0
    kill -0 "$CLEANUP_PID" 2>/dev/null && [ ! -e "$RACE/cleanup-done" ] && WAITED=1
    : >"$RACE/replace"
    REPLACED=1
    wait_file "$RACE/replaced" || REPLACED=0
    : >"$RACE/release"
    wait "$HOLDER_PID" || fail 'the exact lock holder failed'
    if ! wait_file "$RACE/cleanup-done"; then
        kill "$CLEANUP_PID" 2>/dev/null || true
        wait "$CLEANUP_PID" 2>/dev/null || true
        fail 'cleanup did not finish after the holder released the lock'
    fi
    wait "$CLEANUP_PID" || fail 'stale cleanup did not skip safely'
    [ "$WAITED" -eq 1 ] || fail 'cleanup did not wait behind the held mutation lock'
    [ "$REPLACED" -eq 1 ] || fail 'the updater did not publish its replacement intent'
    assert_file "$RACE/.os-migration-pending" '2.0.0|B'
    assert_file "$RACE/.os-data-floor.prev" 2.0.0
    assert_file "$RACE/.os-data-floor" 2.0.0
    assert_no_call "$RACE" 'mark-bad other'
fi

rig_case() (
    local dir="$1" ownership rig
    cd "$dir" || exit 99
    fixture_env "$dir" B
    printf 'rig\n' >machine-role
    # shellcheck source=/dev/null
    source "$ROOT/os/overlay/pithead-boot"
    fail_boot() { exit 1; }
    boot_gate_passed() { printf 'gate-passed\n' >>"$dir/calls"; }
    timeout() {
        shift
        "$@"
    }
    systemctl() { return 0; }
    ownership=$(sed -n '/^hold_chain=0$/,/^esac$/p' "$ROOT/os/overlay/pithead-boot")
    rig=$(sed -n '/^if \[ -f machine-role \]/,/^fi$/p' "$ROOT/os/overlay/pithead-boot")
    eval "$ownership"
    eval "$rig"
)

RIG=$(new_fixture rig-migration 2.0.0 B '2.0.0|B')
rig_case "$RIG" >"$RIG/out" 2>&1 || fail 'migrating rig did not commit'
assert_absent "$RIG/.os-data-floor.prev"
assert_absent "$RIG/.os-migration-pending"
assert_call "$RIG" 'pithead local-miner'
(
    cd "$RIG" || exit 99
    fixture_env "$RIG" B
    # shellcheck source=/dev/null
    source "$RIG/pithead"
    set +e
    os_prepare_migration_hold
    rc=$?
    set -e
    [ "$rc" -eq 1 ]
) || fail 'a committed rig left the next update blocked'

printf 'selftest-migration-boot: PASS\n'
