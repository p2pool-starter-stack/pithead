#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
STACK="$ROOT/pithead"
WORK=$(mktemp -d "${TMPDIR:-/tmp}/pithead-impl-launcher.XXXXXX")
trap 'rm -rf "$WORK"' EXIT
CHECKS=0

echo "== unit: per-piece PITHEAD_IMPL launcher and release-default table (#4214) =="

fail() {
    printf 'FAIL: %s\n' "$1" >&2
    [ -z "${2:-}" ] || printf '  %s\n' "$2" >&2
    exit 1
}

check() {
    CHECKS=$((CHECKS + 1))
    [ "$2" = "$3" ] || fail "$1" "expected [$3], got [$2]"
    printf '.'
}

check_contains() {
    CHECKS=$((CHECKS + 1))
    case "$2" in
    *"$3"*) printf '.' ;;
    *) fail "$1" "[$2] missing [$3]" ;;
    esac
}

check_missing() {
    CHECKS=$((CHECKS + 1))
    case "$2" in
    *"$3"*) fail "$1" "[$2] unexpectedly contains [$3]" ;;
    *) printf '.' ;;
    esac
}

probe() {
    bash -c 'source "$1" >/dev/null 2>&1 || exit 9; shift; "$@"' _ "$STACK" "$@"
}

mode_for() {
    probe _pithead_impl_mode_for "$1" "$2"
}

for v in help -h --help version -V --version status doctor; do
    check "the table default runs $v in Bash" "$(mode_for "$v" "")" "bash"
done
check "a verb with no piece runs in Bash" "$(mode_for apply "")" "bash"
check "selecting help selects Go for version" "$(mode_for version help)" "go"
check "selecting help selects Go for --version" "$(mode_for --version help)" "go"
check "selecting help selects Go for -h" "$(mode_for -h help)" "go"
check "selecting help leaves status in Bash" "$(mode_for status help)" "bash"
check "selecting help leaves doctor in Bash" "$(mode_for doctor help)" "bash"
check "selecting status leaves version in Bash" "$(mode_for version status)" "bash"
check "bash forces Bash for a listed piece" "$(mode_for version bash,help)" "bash"
check "two listed pieces both select Go" "$(mode_for doctor help,doctor)" "go"
check "a trailing comma is not an entry" "$(mode_for version help,)" "go"
check "a verb with no piece ignores a selection" "$(mode_for apply help)" "bash"
check "an internal piece selects through the table" \
    "$(probe _pithead_impl_mode_for_piece config-document config-document)" "go"
check "an unlisted internal piece stays in Bash" \
    "$(probe _pithead_impl_mode_for_piece config-document help)" "bash"

out=$(PITHEAD_IMPL=go "$STACK" version 2>&1) && rc=0 || rc=$?
check "the whole-binary value go is refused" "$rc" "1"
check_contains "the refusal names the unknown piece" "$out" "unknown piece 'go'"
check_contains "the refusal lists the real pieces" "$out" "payout-keys"
out=$(PITHEAD_IMPL=help,bogus "$STACK" version 2>&1) && rc=0 || rc=$?
check "an unknown list entry is refused" "$rc" "1"
check_contains "the refusal names that entry" "$out" "unknown piece 'bogus'"
out=$(PITHEAD_IMPL=bash,bogus "$STACK" version 2>&1) && rc=0 || rc=$?
check "an unknown entry behind bash is refused" "$rc" "1"
check_contains "the bash-first refusal names that entry" "$out" "unknown piece 'bogus'"

cat >"$WORK/fake-go" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$*" >"$WORK/go-argv"
printf '%s\n' "\${PITHEAD_GO_REFERENCE-unset}" >"$WORK/go-ref"
echo go-out
echo go-err >&2
exit 7
EOF
cat >"$WORK/reexec-go" <<EOF
#!/usr/bin/env bash
printf x >>"$WORK/reexec-count"
exec env PITHEAD_IMPL=bash bash "\${PITHEAD_GO_REFERENCE:?}" "\$@"
EOF
chmod +x "$WORK/fake-go" "$WORK/reexec-go"

out=$(PITHEAD_IMPL=help "$STACK" version 2>&1) && rc=0 || rc=$?
check "a missing Go side falls back to Bash" "$rc" "0"
check_contains "the fallback still answers the version verb" "$out" "VERSION"

mkdir -p "$WORK/go-dir"
out=$(PITHEAD_IMPL=help PITHEAD_GO_BINARY="$WORK/go-dir" "$STACK" version 2>&1) && rc=0 || rc=$?
check "a Go side that is not a regular file falls back to Bash" "$rc" "0"
check_contains "the non-file fallback still answers version" "$out" "VERSION"

out=$(PITHEAD_IMPL=help PITHEAD_GO_BINARY="$WORK/fake-go" "$STACK" version 2>"$WORK/go-stderr") && rc=0 || rc=$?
check "the Go side's exit status passes through" "$rc" "7"
check "the Go side's stdout passes through" "$out" "go-out"
check "the Go side's stderr passes through" "$(cat "$WORK/go-stderr")" "go-err"
check "the Go side received the original argv" "$(cat "$WORK/go-argv")" "version"
ref="$(cat "$WORK/go-ref")"
check "PITHEAD_GO_REFERENCE names the entry point" "$(basename -- "$ref")" "pithead"
check "PITHEAD_GO_REFERENCE is executable" "$([ -x "$ref" ] && echo yes)" "yes"
check "PITHEAD_GO_REFERENCE is this stack's entry point" \
    "$(cd "$(dirname -- "$ref")" && pwd -P)" "$(cd "$ROOT" && pwd -P)"

printf 'PITHEAD_IMPL=help\n' >"$WORK/impl"
out=$(env -i PATH="$PATH" PITHEAD_IMPL_FILE="$WORK/impl" "$STACK" version 2>&1) && rc=0 || rc=$?
check "a bare environment reads the file, and a missing Go side falls back" "$rc" "0"
check_contains "the timer-style run still answers version" "$out" "VERSION"
out=$(env -i PATH="$PATH" PITHEAD_IMPL_FILE="$WORK/impl" PITHEAD_GO_BINARY="$WORK/fake-go" "$STACK" version 2>&1) && rc=0 || rc=$?
check "a bare environment selects the piece the file names" "$rc" "7"
rm -f "$WORK/go-argv" "$WORK/go-ref"
out=$(PITHEAD_IMPL=bash PITHEAD_IMPL_FILE="$WORK/impl" PITHEAD_GO_BINARY="$WORK/fake-go" "$STACK" version 2>&1) && rc=0 || rc=$?
check "the environment's bash wins over the file" "$rc" "0"
check_missing "the forced-Bash run never reached the Go side" "$out" "go-out"
check "the forced-Bash run never execed the Go side" "$([ -e "$WORK/go-argv" ] && echo yes || echo no)" "no"

printf 'PITHEAD_IMPL=go\n' >"$WORK/impl-badpiece"
out=$(env -u PITHEAD_IMPL PITHEAD_IMPL_FILE="$WORK/impl-badpiece" "$STACK" version 2>&1) && rc=0 || rc=$?
check "a file naming an unknown piece is refused" "$rc" "1"
check_contains "the file refusal names the unknown piece" "$out" "unknown piece 'go'"
printf 'help\n' >"$WORK/impl-format"
out=$(env -u PITHEAD_IMPL PITHEAD_IMPL_FILE="$WORK/impl-format" "$STACK" version 2>&1) && rc=0 || rc=$?
check "a file without the PITHEAD_IMPL= line is refused" "$rc" "1"
check_contains "the format refusal states the required line" "$out" "PITHEAD_IMPL=<selection>"
printf 'PITHEAD_IMPL=help\nPITHEAD_IMPL=bash\n' >"$WORK/impl-two"
out=$(env -u PITHEAD_IMPL PITHEAD_IMPL_FILE="$WORK/impl-two" "$STACK" version 2>&1) && rc=0 || rc=$?
check "a two-line file is refused" "$rc" "1"
printf 'PITHEAD_IMPL=help\n' >"$WORK/impl-perm"
chmod 666 "$WORK/impl-perm"
out=$(env -u PITHEAD_IMPL PITHEAD_IMPL_FILE="$WORK/impl-perm" "$STACK" version 2>&1) && rc=0 || rc=$?
check "a group-writable file is refused" "$rc" "1"
check_contains "the permission refusal says why" "$out" "writable"
ln -s "$WORK/impl" "$WORK/impl-link"
out=$(env -u PITHEAD_IMPL PITHEAD_IMPL_FILE="$WORK/impl-link" "$STACK" version 2>&1) && rc=0 || rc=$?
check "a symlinked file is refused" "$rc" "1"
ln -s /nonexistent "$WORK/impl-dangling"
out=$(env -u PITHEAD_IMPL PITHEAD_IMPL_FILE="$WORK/impl-dangling" "$STACK" version 2>&1) && rc=0 || rc=$?
check "a dangling symlinked file is refused too" "$rc" "1"
printf 'PITHEAD_IMPL=help\n' >"$WORK/impl-unreadable"
chmod 000 "$WORK/impl-unreadable"
out=$(env -u PITHEAD_IMPL PITHEAD_IMPL_FILE="$WORK/impl-unreadable" "$STACK" version 2>&1) && rc=0 || rc=$?
check "an unreadable file is refused, not crashed on" "$rc" "1"
check_contains "the unreadable refusal says why" "$out" "not readable"
check_missing "the unreadable refusal is not a shell crash" "$out" "unbound variable"

rm -f "$WORK/reexec-count"
out=$(timeout 60 env PITHEAD_IMPL=help PITHEAD_GO_BINARY="$WORK/reexec-go" "$STACK" version 2>&1) && rc=0 || rc=$?
check "the documented hand-back to Bash completes" "$rc" "0"
check "the Go side ran exactly once, without recursion" "$(cat "$WORK/reexec-count")" "x"
check_contains "the handed-back run answers version" "$out" "VERSION"

cat >"$WORK/loop-go" <<EOF
#!/usr/bin/env bash
printf x >>"$WORK/loop-count"
exec bash "\${PITHEAD_GO_REFERENCE:?}" "\$@"
EOF
chmod +x "$WORK/loop-go"
rm -f "$WORK/loop-count"
out=$(timeout 60 env PITHEAD_IMPL=help PITHEAD_GO_BINARY="$WORK/loop-go" "$STACK" version 2>&1) && rc=0 || rc=$?
check "a hand-back that forgets PITHEAD_IMPL=bash still terminates" "$rc" "0"
check "the launched guard execed the Go side exactly once" "$(cat "$WORK/loop-count")" "x"
check_contains "the guarded run answers version in Bash" "$out" "VERSION"

DOC="$ROOT/docs/dev/go-port/selection.md"
check "the selection doc exists" "$([ -f "$DOC" ] && echo yes)" "yes"
doc_text=$(cat "$DOC")
table_rows=$(probe _pithead_impl_table)
doc_table_rows=$(grep -c '^| `' "$DOC" || true)
table_count=$(printf '%s\n' "$table_rows" | grep -c .)
check "the doc table is not empty" "$([ "$doc_table_rows" -gt 0 ] && echo yes)" "yes"
check "the doc table holds exactly the table's rows" "$doc_table_rows" "$table_count"
while read -r name default flip; do
    [ -n "$name" ] || continue
    row=$(printf '| `%s` | `%s` | %s |' "$name" "$default" "$flip")
    check_contains "the doc table row for $name matches the table" "$doc_text" "$row"
done <<EOF_TABLE
$table_rows
EOF_TABLE
CHECKS=$((CHECKS + 1))
grep -qF '| `not-a-piece` |' "$DOC" && fail "the doc table carries no foreign piece" || true
printf '.'
map_rows=$(probe _pithead_impl_verb_map)
doc_map_rows=$(grep -c -- '^- `' "$DOC" || true)
map_count=$(printf '%s\n' "$map_rows" | grep -c .)
check "the doc map is not empty" "$([ "$doc_map_rows" -gt 0 ] && echo yes)" "yes"
check "the doc map holds exactly the map's rows" "$doc_map_rows" "$map_count"
while read -r verb piece; do
    [ -n "$verb" ] || continue
    line=$(printf -- '- `%s` -> `%s`' "$verb" "$piece")
    check_contains "the doc map row for $verb matches the map" "$doc_text" "$line"
done <<EOF_MAP
$map_rows
EOF_MAP

out=$(env PITHEAD_IMPL=go PITHEAD_IMPL_FILE=/nonexistent PITHEAD_GO_BINARY=/nonexistent PITHEAD_GO_REFERENCE=/nonexistent bash -c '
    source "$1/tests/stack/lib.sh" >/dev/null 2>&1 || exit 9
    printf "[%s]" "${PITHEAD_IMPL-unset}" "${PITHEAD_IMPL_FILE-unset}" "${PITHEAD_GO_BINARY-unset}" "${PITHEAD_GO_REFERENCE-unset}"
' _ "$ROOT" 2>/dev/null || true)
check "the stack lib scrubs the selector from sourced suites" "$out" "[unset][unset][unset][unset]"

printf '\nPASS: per-piece PITHEAD_IMPL launcher (%s checks)\n' "$CHECKS"
