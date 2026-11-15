#!/usr/bin/env bash
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$HERE/../lib.sh"
source "$HERE/../lib/borrow-fixture.sh"
source "$HERE/../lib/borrow-rearm.sh"

echo "== RigForge writes re-arm the borrowed pool before worker-dependent phases (#1994) =="
MAIN_SRC="$(sed -n '/^main() {$/,/^}$/p' "$HERE/../run.sh")"
control_line="$(printf '%s\n' "$MAIN_SRC" | grep -n 'run_rigforge_control ||' | cut -d: -f1)"
rearm_line="$(printf '%s\n' "$MAIN_SRC" | grep -n 'wait_borrow_rearm' | cut -d: -f1)"
lifecycle_line="$(printf '%s\n' "$MAIN_SRC" | grep -n 'run_lifecycle' | cut -d: -f1)"
subnet_line="$(printf '%s\n' "$MAIN_SRC" | grep -n 'run_subnet_scenario' | tail -n1 | cut -d: -f1)"
assert_eq "verified pool re-arm is after RigForge control and before lifecycle/subnet" \
    "$([ "$control_line" -lt "$rearm_line" ] && [ "$rearm_line" -lt "$lifecycle_line" ] && [ "$rearm_line" -lt "$subnet_line" ] && echo yes)" "yes"

assert_eq "subnet runs before lifecycle's uninstall removes wallet_data (#3026)" \
    "$([ "$rearm_line" -lt "$subnet_line" ] && [ "$subnet_line" -lt "$lifecycle_line" ] && echo yes)" "yes"

drive_rearm() { # <ack: 0|1> -> request-exists|failure-count
    (
        IT_FAIL=0
        ack_on_wait="$1"
        it_fail() { IT_FAIL=$((IT_FAIL + 1)); }
        it_pass() { :; }
        wait_for() {
            shift 3
            [ "$ack_on_wait" = 1 ] && [ "$1" = _borrow_rearm_ack_matches ] && printf '%s' "$IT_BORROW_REARM_EXPECTED" >"$IT_BORROW_REARM_ACK"
            "$@"
        }
        d="$(mktemp -d)"
        trap 'rm -rf "$d"' EXIT
        IT_BORROW_REARM_REQUEST="$d/request"
        IT_BORROW_REARM_ACK="$d/ack"
        IT_BORROW_REARM_TOKEN=run-123
        wait_borrow_rearm || true
        printf '%s|%s\n' "$(test -f "$IT_BORROW_REARM_REQUEST" && echo yes)" "$IT_FAIL"
    )
}
assert_eq "acknowledged re-arm writes its request and stays green" "$(drive_rearm 1)" "yes|0"
assert_eq "missing re-arm acknowledgement blocks later phases" "$(drive_rearm 0)" "yes|1"

drive_wrong_ack() {
    (
        IT_FAIL=0
        it_fail() { IT_FAIL=$((IT_FAIL + 1)); }
        it_pass() { :; }
        wait_for() {
            shift 3
            "$@"
        }
        d="$(mktemp -d)"
        trap 'rm -rf "$d"' EXIT
        IT_BORROW_REARM_REQUEST="$d/request" IT_BORROW_REARM_ACK="$d/ack" IT_BORROW_REARM_TOKEN=run-123
        printf 'stale-run rearm' >"$IT_BORROW_REARM_ACK"
        wait_borrow_rearm || true
        printf '%s\n' "$IT_FAIL"
    )
}
assert_eq "a stale or different run's acknowledgement is refused" "$(drive_wrong_ack)" "1"

assert_eq "a replay from the same action and run cannot acknowledge a later request" "$(
    d="$(mktemp -d)"
    trap 'rm -rf "$d"' EXIT
    export IT_BORROW_REARM_REQUEST="$d/request" IT_BORROW_REARM_ACK="$d/ack" IT_BORROW_REARM_TOKEN=run-123
    _BORROW_REARM_SEQUENCE=1
    it_fail() { :; }
    it_pass() { :; }
    wait_for() {
        shift 3
        printf 'run-123 rotate-stratum 1' >"$IT_BORROW_REARM_ACK"
        "$@"
    }
    wait_borrow_rearm rotate-stratum
    echo $?
)" 1
assert_eq "the controller cannot observe a partially published request" "$(
    d="$(mktemp -d)"
    trap 'rm -rf "$d"' EXIT
    export IT_BORROW_REARM_REQUEST="$d/request" IT_BORROW_REARM_ACK="$d/ack" IT_BORROW_REARM_TOKEN=run-123
    printf old-request >"$d/request"
    printf() {
        [ ! -e "$d/request" ] || touch "$d/race"
        command printf "$@"
    }
    it_fail() { :; }
    it_pass() { :; }
    wait_for() {
        shift 3
        command printf '%s' "$IT_BORROW_REARM_EXPECTED" >"$IT_BORROW_REARM_ACK"
        "$@"
    }
    wait_borrow_rearm rotate-stratum || exit 1
    [ ! -e "$d/race" ] && echo atomic
)" atomic

assert_eq "a credential-rotation request names its action without the secret" "$(
    d="$(mktemp -d)"
    trap 'rm -rf "$d"' EXIT
    export IT_BORROW_REARM_REQUEST="$d/request" IT_BORROW_REARM_ACK="$d/ack" IT_BORROW_REARM_TOKEN=run-123
    it_fail() { :; }
    it_pass() { :; }
    wait_for() {
        shift 3
        printf '%s' "$IT_BORROW_REARM_EXPECTED" >"$IT_BORROW_REARM_ACK"
        "$@"
    }
    wait_borrow_rearm rotate-stratum
    cat "$IT_BORROW_REARM_REQUEST"
)" "run-123 rotate-stratum 1"

HANDLER_SRC="$(sed -n '/^handle_borrow_rearm() {/,/^}$/p' "$HERE/../lib/borrow-fixture.sh")"
controller_rearm_line="$(printf '%s\n' "$HANDLER_SRC" | grep -n 'repoint_miner ||' | cut -d: -f1)"
controller_workers_line="$(printf '%s\n' "$HANDLER_SRC" | grep -n 'wait_workers "$WORKERS"' | head -n1 | cut -d: -f1)"
controller_ack_line="$(printf '%s\n' "$HANDLER_SRC" | grep -n "cat > '\$ack.tmp'" | tail -n1 | cut -d: -f1)"
assert_eq "controller reloads and observes the worker before acknowledging re-arm" \
    "$([ "$controller_rearm_line" -lt "$controller_workers_line" ] && [ "$controller_workers_line" -le "$controller_ack_line" ] && echo yes)" "yes"

rearm_attempts() { # <attempt that finds the worker, or 0 for never>
    local t
    t="$(mktemp -d)"
    (
        eval "$HANDLER_SRC"
        on_bench() { case "$1" in "cat '"*) printf 'run-9 rearm 1' ;; *) cat >"$t/ack" ;; esac }
        repoint_miner() { echo x >>"$t/repoints"; }
        wait_workers() { [ "$(wc -l <"$t/repoints")" -eq "$1" ]; }
        step() { :; }
        warn() { :; }
        export WORKERS="$1"
        handle_borrow_rearm "$t/req" "$t/ack" run-9 >/dev/null 2>&1
        echo "rc=$? repoints=$(wc -l <"$t/repoints" | tr -d ' ') ack=$(cat "$t/ack" 2>/dev/null || echo none)"
    )
    rm -rf "$t"
}
assert_eq "re-arm restarts the rig again when the first attempt finds no worker" \
    "$(rearm_attempts 2)" "rc=0 repoints=2 ack=run-9 rearm 1"
assert_eq "re-arm gives up without acknowledging after four attempts" \
    "$(rearm_attempts 0)" "rc=1 repoints=4 ack=none"

d="$(mktemp -d)"
trap 'rm -rf "$d"' EXIT
printf '%s' '{"pools":[{"url":"original.example:3333","user":"wallet","pass":"rig"}]}' >"$d/config.json"
cp "$d/config.json" "$d/config.json.e2e-orig.anchor"
export BENCH_HOST=bench.example MINER_XMRIG_CONFIG="$d/config.json" MINER_E2E_BACKUP_DIR="$d/bk" CI_RIG_RECOVERY_HOLD=1
on_miner() { eval "$1"; }
miner_reload() { : >"$d/reloaded"; }
miner_service_active() { return 0; }
wait_for() {
    shift 3
    "$@"
}
step() { :; }
warn() { :; }
repoint_miner
assert_eq "re-arm makes the test stack the rendered primary pool" \
    "$(jq -r '.pools[0].url' "$d/config.json")" "bench.example:3333"
assert_eq "re-arm tags its injected pool for abort-safe recovery" \
    "$(jq -r '.pools[0]["rig-id"]' "$d/config.json")" "pithead-e2e"
assert_eq "re-arm reloads xmrig" "$(test -f "$d/reloaded" && echo yes)" "yes"
assert_eq "re-arm does not mint or replace the original restore anchor" \
    "$(find "$d" -name '*.e2e-orig.*' | awk 'END {print NR}')" "1"
MINER_ROTATE_CFG_BACKUP="$d/config.json.e2e-rotate"
printf 'new-secret' | rotate_borrowed_stratum_password
assert_eq "credential rotation changes only the borrowed test pool password" \
    "$(jq -r '.pools[0].pass' "$d/config.json")" "new-secret"
restore_borrowed_stratum_password
assert_eq "verified config and service restoration clears the phase anchor" "$MINER_ROTATE_CFG_BACKUP" ""
assert_eq "credential rotation restores the exact borrowed config" \
    "$(jq -r '.pools[0].pass' "$d/config.json")" "rig"
miner_reload() { return 1; }
assert_eq "a failed xmrig reload refuses the re-arm" "$(
    repoint_miner >/dev/null 2>&1
    echo $?
)" "1"

MINER_ROTATE_CFG_BACKUP="$d/config.json.e2e-rotate"
printf 'second-secret' | rotate_borrowed_stratum_password || true
restore_borrowed_stratum_password >/dev/null 2>&1
assert_rc "failed service restoration refuses acknowledgement" "$?" 1
assert_eq "failed service restoration retains the exact restore anchor" "$(test -f "$MINER_ROTATE_CFG_BACKUP" && echo yes)" yes
miner_reload() { return 0; }
miner_service_active() { return 1; }
restore_borrowed_stratum_password >/dev/null 2>&1
assert_rc "a restart exit zero without active service is not restoration" "$?" 1
assert_eq "inactive service still retains its recovery anchor" "$(test -f "$MINER_ROTATE_CFG_BACKUP" && echo yes)" yes
CI_RIG_RECOVERY_HOLD=0
printf forbidden | rotate_borrowed_stratum_password
assert_rc "credential writes require the runner's durable-hold capability" "$?" 1
assert_eq "refused write leaves the restored borrowed password unchanged" "$(jq -r '.pools[0].pass' "$d/config.json")" rig

assert_rc "rotation without a controller transport fails closed" "$(
    IT_BORROW_REARM_REQUEST=""
    it_fail() { :; }
    wait_borrow_rearm rotate-stratum
    echo $?
)" 1

MINT_SRC="$(sed -n '/^    on_miner "install -d -m 700/,/^    step "miner config backed up/p' "$HERE/../e2e.sh")"
assert_eq "the mint extraction opens and closes" \
    "$(printf '%s\n' "$MINT_SRC" | sed -n '1p;$p' | awk '{print $1}' | tr '\n' ' ')" "on_miner step "
RECOVERY_SRC="$(sed -n '/^    local leftover borrowed/,/^    esac$/p' "$HERE/../e2e.sh")"
assert_eq "the recovery-block extraction opens and closes" \
    "$(printf '%s\n' "$RECOVERY_SRC" | sed -n '1p;$p' | awk '{print $1}' | tr '\n' ' ')" "local esac "

s="$(mktemp -d)"
trap 'rm -rf "$d" "$s"' EXIT
mkdir -p "$s/data" "$s/worker/xmrig/build"
printf '%s' '{"pools":[{"url":"original.example:3333"}]}' >"$s/worker/xmrig/build/config.json"
MINT_OUT="$(
    exec </dev/null
    MINER_HOST=rig1 MINER_XMRIG_CONFIG="$s/worker/xmrig/build/config.json" MINER_E2E_BACKUP_DIR="$s/data/e2e-backups"
    on_miner() { eval "$1"; }
    step() { :; }
    die() {
        echo "DIE $*"
        exit 1
    }
    miner_reload() { return 0; }
    miner_service_active() { return 0; }
    wait_for() {
        shift 3
        "$@"
    }
    eval "mint() { $MINT_SRC
}"
    mint
    echo "outside=$(find "$s/worker" -name '*.e2e-orig.*' | awk 'END {print NR}')"
    echo "dir_mode=$(ls -ld "$MINER_E2E_BACKUP_DIR" | awk '{print $1}')"
    mv "$s/worker/xmrig" "$s/worker/xmrig-20261109-044418"
    mkdir -p "$s/worker/xmrig/build"
    printf 'rendered-anew' >"$MINER_XMRIG_CONFIG"
    if restore_miner_config "$MINER_CFG_BACKUP"; then echo restored=yes; else echo restored=no; fi
    echo "bytes=$(cat "$MINER_XMRIG_CONFIG")"
    echo "pruned=$(test -f "$MINER_CFG_BACKUP" && echo no || echo yes)"
    echo "archive=$(find "$s/worker" -name '*.e2e-orig.*' | awk 'END {print NR}')"
)"
assert_eq "the mint keeps the anchor outside the whole RigForge worker tree (#3955)" \
    "$(printf '%s\n' "$MINT_OUT" | sed -n 's/^outside=//p')" "0"
assert_eq "the backup dir lands mode 700" \
    "$(printf '%s\n' "$MINT_OUT" | sed -n 's/^dir_mode=//p')" "drwx------"
assert_eq "the anchor survives the staged rebuild that archives the build dir (#3955)" \
    "$(printf '%s\n' "$MINT_OUT" | sed -n 's/^restored=//p')" "yes"
assert_eq "  and the restore puts the original bytes back under MINER_XMRIG_CONFIG" \
    "$(printf '%s\n' "$MINT_OUT" | sed -n 's/^bytes=//p')" '{"pools":[{"url":"original.example:3333"}]}'
assert_eq "  and the verified restore prunes the anchor" \
    "$(printf '%s\n' "$MINT_OUT" | sed -n 's/^pruned=//p')" "yes"
assert_eq "  and nothing named .e2e-orig. rides into the archived tree" \
    "$(printf '%s\n' "$MINT_OUT" | sed -n 's/^archive=//p')" "0"

drive_leftovers() {
    local i old_day=2 new_day=1
    [ "${4:-}" = old ] && {
        old_day=1
        new_day=2
    }
    CFGDIR="$(mktemp -d "$s/cfg.XXXXXX")"
    mkdir -p "$CFGDIR/e2e-backups"
    printf '%s' "$1" >"$CFGDIR/config.json"
    for ((i = 1; i <= $2; i++)); do
        printf '{"pools":[{"url":"old%s.example:3333"}]}' "$i" >"$CFGDIR/config.json.e2e-orig.2026110$old_day-0000$i"
    done
    for ((i = 1; i <= $3; i++)); do
        printf '{"pools":[{"url":"new%s.example:3333"}]}' "$i" >"$CFGDIR/e2e-backups/config.json.e2e-orig.2026110$new_day-0000$i"
    done
    OUT="$(
        exec </dev/null
        # shellcheck disable=SC2034,SC2329
        MINER_HOST=rig1 BENCH_HOST=bench.example
        MINER_XMRIG_CONFIG="$CFGDIR/config.json" MINER_E2E_BACKUP_DIR="$CFGDIR/e2e-backups"
        on_miner() { eval "$1"; }
        warn() { echo "WARN $*"; }
        die() { echo "DIE $*" && exit 1; }
        eval "recovery() { $RECOVERY_SRC; }"
        recovery
    )"
}
BORROWED='{"pools":[{"url":"pithead.example:3333"},{"url":"bench.example:3333","rig-id":"pithead-e2e"}]}'
leftover_count() { find "$CFGDIR" -name '*.e2e-orig.*' | awk 'END {print NR}'; }

drive_leftovers "$BORROWED" 0 2
assert_eq "a leftover borrow is restored from the oldest backup in the new location" \
    "$(jq -r '.pools[0].url' "$CFGDIR/config.json")" "new1.example:3333"
assert_eq "  and both locations are cleared once the bytes are back" "$(leftover_count)" "0"

drive_leftovers "$BORROWED" 2 0
assert_eq "a leftover found only in the old adjacent location still recovers (#3955)" \
    "$(jq -r '.pools[0].url' "$CFGDIR/config.json")" "old1.example:3333"
assert_eq "  and its backup is cleared" "$(leftover_count)" "0"

drive_leftovers "$BORROWED" 1 1
assert_eq "with backups in both locations the older one is the original" \
    "$(jq -r '.pools[0].url' "$CFGDIR/config.json")" "new1.example:3333"
assert_eq "  and every backup in both locations is pruned" "$(leftover_count)" "0"

drive_leftovers "$BORROWED" 1 1 old
assert_eq "  and the same holds when the old location holds the older backup" \
    "$(jq -r '.pools[0].url' "$CFGDIR/config.json")" "old1.example:3333"
assert_eq "  with both locations cleared" "$(leftover_count)" "0"

drive_leftovers '{"pools":[{"url":"pithead.example:3333"}]}' 1 1
assert_eq "a rig that is not borrowed keeps its config bytes" \
    "$(cat "$CFGDIR/config.json")" '{"pools":[{"url":"pithead.example:3333"}]}'
assert_eq "  and its stale backups are cleared from BOTH locations so oldest keeps meaning" "$(leftover_count)" "0"

drive_leftovers 'not json at all' 0 1
assert_eq "an unreadable config leaves the new-location backup alone" "$(leftover_count)" "1"
assert_eq "  and the silence is not reported as clean" "$(printf '%s\n' "$OUT" | grep -c 'untouched')" "1"

echo "selftest-borrow-rearm: $IT_PASS passed, $IT_FAIL failed"
[ "$IT_FAIL" -eq 0 ] || exit 1
