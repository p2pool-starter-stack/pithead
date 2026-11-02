#!/usr/bin/env bash
set -Eeuo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
: "${TMPDIR:=/tmp}"
T=$(mktemp -d "$TMPDIR/migration-install.XXXXXX")
trap 'rm -rf "$T"' EXIT

fail() {
    printf 'selftest-migration-install: FAIL: %s\n' "$*" >&2
    [ ! -f "$T/out" ] || tail -20 "$T/out" >&2
    [ ! -f "$T/calls" ] || tail -20 "$T/calls" >&2
    exit 1
}

assert_file() {
    local path="$1" expected="$2" actual
    [ -f "$path" ] || fail "$path is absent"
    actual=$(tr -d ' \t\r\n' <"$path")
    [ "$actual" = "$expected" ] || fail "$path: expected [$expected], got [$actual]"
}

assert_absent() {
    [ ! -e "$1" ] || fail "$1 is present"
}

assert_called() {
    grep -Fqx "$1" "$T/calls" || fail "missing call: $1"
}

assert_not_called() {
    ! grep -Fq "$1" "$T/calls" || fail "unexpected call containing: $1"
}

assert_before() {
    local first second first_line second_line
    first="$1"
    second="$2"
    first_line=$(grep -n -m1 -Fx "$first" "$T/calls" | cut -d: -f1)
    second_line=$(grep -n -m1 -Fx "$second" "$T/calls" | cut -d: -f1)
    [ -n "$first_line" ] && [ -n "$second_line" ] && [ "$first_line" -lt "$second_line" ] ||
        fail "call order: $first before $second"
}

assert_exact_before() {
    local first_line second_line
    first_line=$(grep -n -m1 -Fx "$1" "$T/calls" | cut -d: -f1)
    second_line=$(grep -n -m1 -Fx "$2" "$T/calls" | cut -d: -f1)
    [ -n "$first_line" ] && [ -n "$second_line" ] && [ "$first_line" -lt "$second_line" ] ||
        fail "call order: [$1] before [$2]"
}

assert_later_exact() {
    local first rest
    first=$(grep -n -m1 -F "$1" "$T/calls" | cut -d: -f1)
    [ -n "$first" ] || fail "missing call containing: $1"
    rest=$(tail -n "+$((first + 1))" "$T/calls")
    grep -Fqx "$2" <<<"$rest" || fail "no [$2] after [$1]"
}

assert_later_exact_count() {
    local first rest count
    first=$(grep -n -m1 -F "$1" "$T/calls" | cut -d: -f1)
    [ -n "$first" ] || fail "missing call containing: $1"
    rest=$(tail -n "+$((first + 1))" "$T/calls")
    count=$(grep -Fxc "$2" <<<"$rest" || true)
    [ "$count" -ge "$3" ] || fail "fewer than $3 [$2] calls after [$1]"
}

mkdir -p "$T/bin"
touch "$T/update.raucb"
cp "$ROOT/pithead" "$T/pithead"
printf '1.5.0\n' >"$T/VERSION"
printf 'release\n' >"$T/variant"
printf 'TARI_MODE=off\n' >"$T/env"

cat >"$T/bin/rauc" <<'EOF'
#!/usr/bin/env bash
printf 'rauc %s\n' "$*" >>"${CALLS:?}"
case "$1" in
info)
    printf "RAUC_META_PITHEAD_VARIANT='release'\n"
    printf "RAUC_META_PITHEAD_VERSION='%s'\n" "${BUNDLE_VERSION:-2.0.0}"
    printf "RAUC_META_PITHEAD_DATA_MIGRATION='%s'\n" "${BUNDLE_MIGRATES:-true}"
    [ "${BUNDLE_MINIMUM+x}" != x ] || printf "RAUC_META_PITHEAD_MINIMUM_OS_VERSION='%s'\n" "$BUNDLE_MINIMUM"
    ;;
status)
    if [ "$*" = 'status --output-format=json' ]; then
        if [ "${RAUC_STATUS_MALFORMED:-0}" = 1 ]; then
            printf '{broken\n'
        else
            printf '{"booted":"A","slots":[{"rootfs.0":{"bootname":"A","state":"booted","boot_status":"%s"}},{"rootfs.1":{"bootname":"B","state":"inactive","boot_status":"bad"}}]}\n' "${RAUC_BOOT_STATUS:-good}"
        fi
        exit 0
    fi
    [ "$*" = 'status mark-bad other' ] || exit 91
    exit "${RAUC_MARK_BAD_RC:-0}"
    ;;
install)
    if [ "${EXPECT_PREPARED:-0}" = 1 ]; then
        [ "$(tr -d ' \t\r\n' <"${FLOOR:?}")" = "${BUNDLE_MINIMUM:-2.0.0}" ] || exit 92
        [ "$(tr -d ' \t\r\n' <"$FLOOR.prev")" = "${EXPECTED_PREVIOUS:-1.5.0}" ] || exit 93
        [ "$(tr -d ' \t\r\n' <"${MARKER:?}")" = "${BUNDLE_VERSION:-2.0.0}|B" ] || exit 94
    fi
    if [ "${RAUC_INSTALL_KILL:-0}" = 1 ]; then
        printf 'activated\n' >"${ACTIVATED:?}"
        kill -KILL "$PPID"
        exit 95
    fi
    exit "${RAUC_INSTALL_RC:-0}"
    ;;
*) exit 96 ;;
esac
EOF

cat >"$T/bin/sync" <<'EOF'
#!/usr/bin/env bash
printf 'sync %s\n' "$*" >>"${CALLS:?}"
if [ "${SYNC_FAIL_AFTER_MARK_BAD:-0}" = 1 ] && grep -Fqx 'rauc status mark-bad other' "${CALLS:?}"; then
    exit 1
fi
exit 0
EOF
chmod +x "$T/bin/rauc" "$T/bin/sync"

reset_fixture() {
    rm -f "$T/floor" "$T/floor.prev" "$T/marker" "$T/activated" "$T/out"
    : >"$T/calls"
    printf 'quiet rauc.slot=A\n' >"$T/cmdline"
    printf '1.5.0\n' >"$T/floor"
}

run_update() {
    local rc=0
    (
        cd "$T" || exit 99
        PATH="$T/bin:$PATH" CALLS="$T/calls" FLOOR="$T/floor" MARKER="$T/marker" \
            ACTIVATED="$T/activated" PITHEAD_VERSION=1.5.0 PITHEAD_VARIANT_FILE="$T/variant" \
            PITHEAD_ENV_FILE="$T/env" PITHEAD_LOCK_FILE="$T/lock" PITHEAD_CMDLINE="$T/cmdline" \
            PITHEAD_DATA_FLOOR_FILE="$T/floor" PITHEAD_MIGRATION_MARKER_FILE="$T/marker" \
            BUNDLE_VERSION="${BUNDLE_VERSION:-2.0.0}" BUNDLE_MIGRATES="${BUNDLE_MIGRATES:-true}" \
            BUNDLE_MINIMUM="${BUNDLE_MINIMUM-2.0.0}" EXPECT_PREPARED="${EXPECT_PREPARED:-0}" \
            EXPECTED_PREVIOUS="${EXPECTED_PREVIOUS:-1.5.0}" RAUC_INSTALL_RC="${RAUC_INSTALL_RC:-0}" \
            RAUC_INSTALL_KILL="${RAUC_INSTALL_KILL:-0}" RAUC_MARK_BAD_RC="${RAUC_MARK_BAD_RC:-0}" \
            RAUC_BOOT_STATUS="${RAUC_BOOT_STATUS:-good}" RAUC_STATUS_MALFORMED="${RAUC_STATUS_MALFORMED:-0}" \
            SYNC_FAIL_AFTER_MARK_BAD="${SYNC_FAIL_AFTER_MARK_BAD:-0}" \
            "$T/pithead" os-update "$T/update.raucb" --yes
    ) >"$T/out" 2>&1 || rc=$?
    return "$rc"
}

reset_fixture
set +e
RAUC_INSTALL_KILL=1 run_update 2>/dev/null
rc=$?
set -e
[ "$rc" -eq 137 ] || fail "interrupted install returned $rc, expected 137"
assert_file "$T/activated" activated
assert_file "$T/floor" 2.0.0
assert_file "$T/floor.prev" 1.5.0
assert_file "$T/marker" '2.0.0|B'

reset_fixture
EXPECT_PREPARED=1 run_update || fail 'completed migrating install failed'
assert_file "$T/floor" 2.0.0
assert_file "$T/floor.prev" 1.5.0
assert_file "$T/marker" '2.0.0|B'
assert_called "sync -f $T/floor.prev"
assert_called "sync -f $T/marker"
assert_called "sync -f $T/floor"
assert_exact_before "sync -f $T/floor.prev" "sync -f $T/marker"
assert_exact_before "sync -f $T/marker" "sync -f $T/floor"
assert_exact_before "sync -f $T/floor" "rauc install $T/update.raucb"

reset_fixture
set +e
EXPECT_PREPARED=1 RAUC_INSTALL_RC=1 run_update
rc=$?
set -e
[ "$rc" -eq 1 ] || fail "terminal install failure returned $rc"
assert_called 'rauc status mark-bad other'
assert_later_exact_count 'rauc status mark-bad other' 'sync ' 2
assert_file "$T/floor" 1.5.0
assert_absent "$T/floor.prev"
assert_absent "$T/marker"

reset_fixture
set +e
EXPECT_PREPARED=1 RAUC_INSTALL_RC=2 run_update
rc=$?
set -e
[ "$rc" -eq 1 ] || fail "ambiguous install failure returned $rc"
assert_file "$T/floor" 2.0.0
assert_file "$T/floor.prev" 1.5.0
assert_file "$T/marker" '2.0.0|B'

for disarm in mark sync; do
    reset_fixture
    set +e
    if [ "$disarm" = mark ]; then
        EXPECT_PREPARED=1 RAUC_INSTALL_RC=1 RAUC_MARK_BAD_RC=1 run_update
    else
        EXPECT_PREPARED=1 RAUC_INSTALL_RC=1 SYNC_FAIL_AFTER_MARK_BAD=1 run_update
    fi
    rc=$?
    set -e
    [ "$rc" -eq 1 ] || fail "$disarm disarm failure returned $rc"
    assert_file "$T/floor" 2.0.0
    assert_file "$T/floor.prev" 1.5.0
    assert_file "$T/marker" '2.0.0|B'
done

reset_fixture
printf '1.9.0\n' >"$T/floor"
printf '1.5.0\n' >"$T/floor.prev"
printf '1.9.0|B\n' >"$T/marker"
EXPECTED_PREVIOUS=1.5.0 EXPECT_PREPARED=1 run_update || fail 'superseding install failed'
assert_called 'rauc status mark-bad other'
assert_later_exact 'rauc status mark-bad other' 'sync '
assert_before 'rauc status mark-bad other' "rauc install $T/update.raucb"
assert_exact_before 'sync ' "sync -f $T/floor.prev"
assert_file "$T/floor" 2.0.0
assert_file "$T/floor.prev" 1.5.0
assert_file "$T/marker" '2.0.0|B'

for status_case in bad malformed; do
    reset_fixture
    printf '1.9.0\n' >"$T/floor"
    printf '1.5.0\n' >"$T/floor.prev"
    printf '1.9.0|B\n' >"$T/marker"
    set +e
    if [ "$status_case" = bad ]; then
        RAUC_BOOT_STATUS=bad run_update
    else
        RAUC_STATUS_MALFORMED=1 run_update
    fi
    rc=$?
    set -e
    [ "$rc" -eq 1 ] || fail "$status_case source-slot status returned $rc"
    assert_file "$T/floor" 1.9.0
    assert_file "$T/floor.prev" 1.5.0
    assert_file "$T/marker" '1.9.0|B'
    assert_not_called 'rauc status mark-bad other'
    assert_not_called 'rauc install '
done

for ownership in current different-version corrupt; do
    reset_fixture
    if [ "$ownership" = current ]; then
        printf '1.5.0|A\n' >"$T/marker"
    elif [ "$ownership" = different-version ]; then
        printf '2.0.0|A\n' >"$T/marker"
    else
        printf 'not-an-owner\n' >"$T/marker"
    fi
    set +e
    run_update
    rc=$?
    set -e
    [ "$rc" -eq 1 ] || fail "$ownership ownership returned $rc"
    assert_not_called 'rauc install '
done

for metadata in bad-version missing-minimum bad-minimum; do
    reset_fixture
    set +e
    case "$metadata" in
    bad-version) BUNDLE_VERSION=broken run_update ;;
    missing-minimum) BUNDLE_MINIMUM='' run_update ;;
    bad-minimum) BUNDLE_MINIMUM=broken run_update ;;
    esac
    rc=$?
    set -e
    [ "$rc" -eq 1 ] || fail "$metadata returned $rc"
    assert_not_called 'rauc install '
done

for cmdline in missing duplicate; do
    reset_fixture
    if [ "$cmdline" = missing ]; then
        printf 'quiet\n' >"$T/cmdline"
    else
        printf 'rauc.slot=A rauc.slot=B\n' >"$T/cmdline"
    fi
    set +e
    run_update
    rc=$?
    set -e
    [ "$rc" -eq 1 ] || fail "$cmdline slot returned $rc"
    assert_not_called 'rauc install '
done

printf 'selftest-migration-install: PASS\n'
