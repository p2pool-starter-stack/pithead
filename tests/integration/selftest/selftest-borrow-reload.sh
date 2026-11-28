#!/usr/bin/env bash
# shellcheck disable=SC2034
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$HERE/../lib.sh"

echo "== the borrow moves a root-run rig and the worker gate names it (#3972) =="
reload_rc() {
    (
        source "$HERE/../lib/borrow-fixture.sh"
        pid=100 restart_ok="$1" stopstart_ok="$2" moves="$3" user_ok="$4"
        on_miner() { eval "$1"; }
        sleep() { :; }
        systemctl() {
            case "$*" in
            *"show -p MainPID"*) echo "$pid" ;;
            "--user restart xmrig") [ "$user_ok" = 1 ] && pid=300 ;;
            esac
        }
        sudo() {
            shift
            case "$2" in
            restart) [ "$restart_ok" = 1 ] ;;
            stop) [ "$stopstart_ok" != 0 ] ;;
            start)
                [ "$stopstart_ok" = 3 ] && [ -z "${started_once:-}" ] && {
                    started_once=1
                    return 1
                }
                [ "$stopstart_ok" = 1 ] || [ "$stopstart_ok" = 3 ] && {
                    [ "$moves" = 1 ] && pid=200
                    true
                }
                ;;
            esac
        }
        pkill() { return 0; }
        miner_reload
        echo $?
    )
}
assert_eq "stop then start reloads a root-run xmrig when restart is refused" "$(reload_rc 0 1 1 0 0)" 0
assert_eq "a start that leaves the same MainPID is not a reload" "$(reload_rc 0 1 0 0 0)" 1
assert_eq "a stop that succeeds with a failed start fails loudly" "$(reload_rc 0 2 1 1 0)" 1
assert_eq "one failed start after a stop is retried and reloads" "$(reload_rc 0 3 1 0)" 0
assert_eq "a user unit restart that moves its MainPID is a reload" "$(reload_rc 0 0 0 1 0)" 0
assert_eq "refused restart, refused stop and no user unit fail loudly" "$(reload_rc 0 0 0 0 0)" 1
assert_eq "a signal that would reach xmrig is never a fallback" "$(reload_rc 0 0 0 0 1)" 1

worker_gate() {
    (
        source "$HERE/../lib/borrow-fixture.sh"
        rows="$1"
        ok() { :; }
        warn() { :; }
        FAKE_NOW=0
        sleep() { FAKE_NOW=$((FAKE_NOW + 100)); }
        date() { echo "$FAKE_NOW"; }
        curl() { printf '{"proxy_workers":1,"workers":%s}' "$rows"; }
        on_bench() { eval "$1"; }
        wait_workers 1 5 "$2" >/dev/null
        echo $?
    )
}
assert_eq "every re-arm attempt waits for the borrowed rig by name" "$(
    (
        source "$HERE/../lib/borrow-fixture.sh"
        seen="$(mktemp)"
        trap 'rm -f "$seen"' EXIT
        on_bench() { if [ "$1" = "cat 'req'" ]; then echo "run-1 rearm 1"; else cat >/dev/null; fi; }
        repoint_miner() { :; }
        step() { :; }
        warn() { :; }
        wait_workers() {
            echo "$3" >>"$seen"
            [ "$(wc -l <"$seen")" -ge 2 ]
        }
        WORKERS=1
        handle_borrow_rearm req ack run-1 >/dev/null
        sort -u "$seen" | tr '\n' ' '
        wc -l <"$seen" | tr -d ' '
    ) | tr '\n' ' '
)" "pithead-e2e 2 "
assert_eq "another online worker does not satisfy the named-rig gate" \
    "$(worker_gate '[{"name":"other","status":"online"}]' pithead-e2e)" 1
assert_eq "an offline worker of the borrowed name does not satisfy the gate" \
    "$(worker_gate '[{"name":"pithead-e2e","status":"offline"}]' pithead-e2e)" 1
assert_eq "the borrowed rig online satisfies the gate" \
    "$(worker_gate '[{"name":"other","status":"online"},{"name":"pithead-e2e","status":"online"}]' pithead-e2e)" 0
assert_eq "the bench's own rig-id tags the pool even when the pool pre-exists" "$(
    source "$HERE/../lib/borrow-fixture.sh"
    d2="$(mktemp -d)"
    printf '%s' '{"pools":[{"url":"bench.example:3333","user":"w"}]}' >"$d2/c.json"
    BENCH_HOST=bench.example MINER_XMRIG_CONFIG="$d2/c.json"
    on_miner() { eval "$1"; }
    step() { :; }
    miner_reload() { :; }
    repoint_miner
    jq -r '.pools[0]["rig-id"]' "$d2/c.json"
    rm -rf "$d2"
)" pithead-e2e

echo "selftest-borrow-reload: $IT_PASS passed, $IT_FAIL failed"
[ "$IT_FAIL" -eq 0 ] || exit 1
