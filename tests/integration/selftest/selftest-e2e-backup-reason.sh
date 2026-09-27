#!/usr/bin/env bash
#
# Self-test for #2757/#2815: a failed safety backup names its exit status and preserves its
# redacted output. Job 1283 died on a bare "pithead backup failed." because backup_stack sent
# output to /dev/null. backup_stack is extracted out of the shipped e2e.sh; on_bench runs its REAL command
# string against a fake `pithead`, so a redirection put back into that command empties the reason.
#
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=tests/integration/lib.sh
source "$HERE/../lib.sh"
# shellcheck source=tests/integration/lib/remote-endpoints.sh
source "$HERE/../lib/remote-endpoints.sh"

echo "== backup_stack names why the safety backup failed =="
SRC="$(sed -n '/^backup_stack() {$/,/^}$/p' "$HERE/../e2e.sh")"
assert_eq "the extraction is the whole function (opens and closes)" \
    "$(printf '%s\n' "$SRC" | sed -n '1p;$p' | tr '\n' ' ')" "backup_stack() { } "

sandbox="$(mktemp -d)"
trap 'rm -rf "$sandbox"' EXIT
# The fake backup fails like a real one would: a line on stdout, the reason on stderr, exit 3.
cat >"$sandbox/pithead" <<'FAKE'
#!/usr/bin/env bash
echo "stopping services"
echo 'Tor after failed backup restart (health and last 40 log lines):'
echo '{"Status":"unhealthy","FailingStreak":2}'
for ((i = 0; i < 25; i++)); do echo "Tor control connection $i"; done
printf '\033[31mTor colored line\033[0m\n'
printf '\23331mTor C1 colored line\2330m\n'
echo "Error: cannot reach node.remote.example: disk full writing archive" >&2
exit 3
FAKE
chmod +x "$sandbox/pithead"

out="$(
    # shellcheck disable=SC2034,SC2329  # used by the eval'd backup_stack
    {
        CANONICAL_DIR="$sandbox"
        REMOTE_NODE_HOSTS=(node.remote.example)
        log() { :; }
        ok() { :; }
        die() {
            echo "DIE $*"
            exit 1
        }
        on_bench() { bash -c "$1"; }
        eval "$SRC"
        backup_stack
    } 2>&1
)"

assert_contains "the failure names the exit status" "$out" "DIE pithead backup failed (exit 3): "
assert_contains "the failure carries the backup's stdout" "$out" "stopping services"
assert_contains "the failure preserves Tor's early health snapshot" "$out" '"FailingStreak":2'
assert_contains "the failure preserves Tor's interior log lines" "$out" "Tor control connection 3"
assert_contains "the failure preserves Tor's final log lines" "$out" "Tor control connection 24"
assert_contains "the failure strips terminal control bytes" "$out" "Tor colored line"
assert_contains "the failure strips C1 terminal control bytes" "$out" "Tor C1 colored line"
assert_contains "the failure carries the backup's stderr reason" "$out" "disk full writing archive"
assert_contains "the remote endpoint in the output is redacted" "$out" "<redacted-endpoint>"
case "$out" in
*node.remote.example*) it_fail "the remote endpoint does not reach the log" "[$out]" ;;
*) it_pass "the remote endpoint does not reach the log" ;;
esac
case "$out" in
*$'\033'*) it_fail "terminal escapes do not reach the log" "[$out]" ;;
*) it_pass "terminal escapes do not reach the log" ;;
esac
case "$out" in
*$'\233'*) it_fail "C1 terminal escapes do not reach the log" "[$out]" ;;
*) it_pass "C1 terminal escapes do not reach the log" ;;
esac

echo ""
printf 'backup-reason self-test: %s passed, %s failed\n' "$IT_PASS" "$IT_FAIL"
[ "$IT_FAIL" -eq 0 ]
