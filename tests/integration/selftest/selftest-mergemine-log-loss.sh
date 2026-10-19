#!/usr/bin/env bash
# The log-loss path needs proof without a live daemon to rotate.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=tests/integration/lib.sh
source "$HERE/../lib.sh"
# shellcheck source=tests/integration/lib/mergemine-probe.sh
source "$HERE/../lib/mergemine-probe.sh"

MM_FIXTURE_START=2026-10-09T02:24:00.000000000Z
MM_FIXTURE_OLDEST=2026-10-09T02:24:01.000000000Z
MM_FIXTURE_STARTUP=""
MM_FIXTURE_RECENT=""
MM_FIXTURE_SYNCED=0
MM_FIXTURE_RECENT_RC=0
MM_READY_TIMEOUT=0 MM_READY_INTERVAL=0
MM_FIXTURE_DIR=$(mktemp -d)
MM_FIXTURE_TRACE="$MM_FIXTURE_DIR/trace"
trap 'rm -rf "$MM_FIXTURE_DIR"' EXIT
mkdir "$MM_FIXTURE_DIR/bin"
printf '%s\n' '#!/usr/bin/env bash' 'shift' 'exec "$@"' >"$MM_FIXTURE_DIR/bin/timeout"
# Fake Docker, not the filters, so the real awk must cut the secret-bearing oldest line to its timestamp.
cat >"$MM_FIXTURE_DIR/bin/docker" <<'MM_DOCKER'
#!/usr/bin/env bash
case "$1" in
inspect)
    case "$*" in
    *.Id*) printf 'fixture-id|%s\n' "$MM_FIXTURE_START" ;;
    *) printf '%s\n' "$MM_FIXTURE_START" ;;
    esac
    ;;
logs) printf '%s wallet=fixture-secret\n' "$MM_FIXTURE_OLDEST" >&2 ;;
compose)
    if [[ " $* " == *" --since 60s "* ]]; then
        printf '%s\n' "$MM_FIXTURE_RECENT"
        exit "$MM_FIXTURE_RECENT_RC"
    fi
    printf '%s\n' "$MM_FIXTURE_STARTUP"
    ;;
*) exit 1 ;;
esac
MM_DOCKER
chmod +x "$MM_FIXTURE_DIR/bin/timeout" "$MM_FIXTURE_DIR/bin/docker"
rx() {
    printf '%s\n' "$1" >>"$MM_FIXTURE_TRACE"
    export MM_FIXTURE_START MM_FIXTURE_OLDEST MM_FIXTURE_STARTUP MM_FIXTURE_RECENT MM_FIXTURE_RECENT_RC
    PATH="$MM_FIXTURE_DIR/bin:$PATH" bash -c "$1"
}
monero_caught_up() { return "$MM_FIXTURE_SYNCED"; }
mm_outcome() {
    (
        IT_PASS=0 IT_FAIL=0 IT_SKIPPED_LEGS=0 IT_SKIPPED_MISSING=0 IT_SKIPPED_BY_DESIGN=0
        assert_mergemine_roundtrip 2>&1
        printf 'COUNTS %s %s %s %s %s\n' "$IT_PASS" "$IT_FAIL" "$IT_SKIPPED_LEGS" "$IT_SKIPPED_MISSING" "$IT_SKIPPED_BY_DESIGN"
    )
}
mm_expect() {
    local out
    out=$(mm_outcome)
    assert_contains "$1" "$out" "COUNTS $2"
}

echo "== retained startup, evidence-loss heuristic and fresh round-trip proof =="

mm_expect "complete startup without a client remains red" "0 1 0 0 0"
MM_FIXTURE_OLDEST=2026-10-09T02:24:17.500000000Z
mm_expect "normal delayed startup without a client remains red" "0 1 0 0 0"
MM_FIXTURE_OLDEST=2026-10-09T02:25:00.000000000Z
mm_expect "exactly 60 seconds remains red" "0 1 0 0 0"
MM_FIXTURE_OLDEST=2026-10-09T02:25:00.000000001Z
mm_expect "beyond 60 seconds without live proof is missing, never pass" "0 0 1 1 0"
MM_FIXTURE_OLDEST=2026-10-08T22:25:00.000000000-04:00
mm_expect "the boundary compares instants across offsets" "0 1 0 0 0"
MM_FIXTURE_START='2026-10-08 22:24:00.000000000 -0400 EDT'
MM_FIXTURE_OLDEST=2026-10-09T16:06:00.000000000Z
mm_expect "rotated regression without live proof is missing" "0 0 1 1 0"
assert_contains "missing explains the conservative evidence-loss heuristic" "$(mm_outcome)" "startup evidence may have been lost"
MM_FIXTURE_SYNCED=2
mm_expect "evidence loss outranks an unanswerable monerod, never by-design" "0 0 1 1 0"
MM_FIXTURE_SYNCED=0
MM_FIXTURE_RECENT='p2pool | MergeMiningClientTari worker thread ready'
mm_expect "a fresh local-only client line cannot pass" "0 0 1 1 0"
MM_FIXTURE_RECENT=$'p2pool | \033[0;90mMergeMiningClientTari \033[0mtari://node.fixture:18142 uses chain_id 0123456789abcdef'
mm_expect "rotated logs with a fresh chain_id round-trip pass" "1 0 0 0 0"
assert_contains "fallback uses a fresh bounded window" "$(cat "$MM_FIXTURE_TRACE")" "--since 60s"
assert_contains "fallback is capped" "$(cat "$MM_FIXTURE_TRACE")" "tail -n 2000"
MM_FIXTURE_STARTUP='p2pool | MergeMiningClientTari worker thread ready'
mm_expect "a retained local-only line can use fresh round-trip proof after evidence loss" "1 0 0 0 0"
MM_FIXTURE_STARTUP=""
MM_FIXTURE_RECENT="$MM_FIXTURE_RECENT
$(for i in {1..2001}; do printf 'p2pool | no merge-mining evidence %s\n' "$i"; done)"
mm_expect "a chain_id outside the bounded fresh window cannot pass" "0 0 1 1 0"
MM_FIXTURE_RECENT_RC=1
MM_FIXTURE_RECENT=""
mm_expect "unreachable fresh proof reports missing" "0 0 1 1 0"
MM_FIXTURE_RECENT_RC=0
MM_FIXTURE_OLDEST=2026-10-09T02:24:01.000000000Z
MM_FIXTURE_RECENT='p2pool | MergeMiningClientTari tari://node.fixture:18142 uses chain_id 0123456789abcdef'
: >"$MM_FIXTURE_TRACE"
mm_expect "complete-log negative control cannot borrow fresh proof" "0 1 0 0 0"
case "$(cat "$MM_FIXTURE_TRACE")" in
*"--since 60s"*) it_fail "complete logs never invoke the fallback" ;;
*) it_pass "complete logs never invoke the fallback" ;;
esac
MM_FIXTURE_OLDEST=not-a-timestamp
mm_expect "an invalid oldest timestamp cannot hide a missing client" "0 1 0 0 0"
MM_FIXTURE_OLDEST=""
mm_expect "an unreadable oldest timestamp cannot hide a missing client" "0 1 0 0 0"

printf 'selftest-mergemine-log-loss: %s passed, %s failed\n' "$IT_PASS" "$IT_FAIL"
[ "$IT_FAIL" -eq 0 ]
