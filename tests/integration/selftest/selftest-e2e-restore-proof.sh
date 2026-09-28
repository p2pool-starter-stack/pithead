#!/usr/bin/env bash
#
# Self-test for the restore's image-identity check (#272, restore side) and for the restore command
# e2e.sh chooses.
#
# The defect it locks down is an ABSENCE, like #1364's. e2e.sh's own comment at deploy_branch says
# `pithead apply` "runs `compose up --pull` (never --build), so it would test whatever images were
# last built on the box, not this branch" — and the restore, at the other end of the same run, used
# exactly that pairing. On a box whose live install is a SOURCE CHECKOUT, `pithead` exports
# STACK_VERSION=dev (export_build_provenance, pithead:4149), so the baseline and the branch under
# test resolve to the SAME `:dev` tag; deploy_branch has already overwritten it, the source-checkout
# pull policy is `never`, and `apply && up` therefore brings the BRANCH back up under the baseline's
# name. Every other restore check stays green on that: the creds are read from the on-disk .env at
# runtime, monerod answers with them, and the control units name RESTORE_DIR either way. The run
# prints "restore complete."
#
# The shipped restore command and identity grader are driven with local stubs. A late scenario
# recreation must fail the proof even when its image was absent from the first branch census.
#
# Standalone (not sourced by selftest.sh), same reasoning as selftest-e2e-phases.sh. Run directly or
# via `make test-integration-selftest`. No server, no bench, no rig, no docker.
#
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=tests/integration/lib.sh
source "$HERE/../lib.sh"

E2E_SRC="$HERE/../e2e.sh"
PROOF_SRC="$HERE/../lib/restore-proof.sh"

# shellcheck source=tests/integration/lib/restore-proof.sh
source "$PROOF_SRC"
assert_eq "restore proof defines the live identity grader" "$(type -t grade_restore_identity)" "function"

BASE='dashboard=sha256:aaa
monerod=sha256:mmm
p2pool=sha256:ppp
tor=sha256:ttt
xmrig-proxy=sha256:xxx'

# --- 2. Which restore command e2e.sh runs -----------------------------------------------------
# The REAL restore_all out of the shipped e2e.sh, evaluated against stubs, so this reads the
# command the box would actually have been given — not a re-implementation of the decision.
RESTORE_SRC="$(sed -n '/^restore_all() {$/,/^}$/p' "$E2E_SRC")"
assert_eq "the extraction is the whole function (opens and closes)" \
    "$(printf '%s\n' "$RESTORE_SRC" | sed -n '1p;$p' | tr '\n' ' ')" "restore_all() { } "

drive_restore() { # <is-source-checkout: yes|no> -> the `cd RESTORE_DIR && ...` command string
    local cf
    cf="$(mktemp)"
    # shellcheck disable=SC2034,SC2329  # read/called by the eval'd restore_all, which shellcheck
    # cannot follow into.
    (
        exec </dev/null
        MODE="${2:-targeted}" RESTORED=0 KEEP=0 MINER_CFG_BACKUP="" RESTORE_DIR=/srv/code/baseline
        E2E_DIR=/srv/code/pithead-e2e BENCH_HOST=bench SAFETY_ARCHIVE=""
        RESTORE_PROOF_FAILED=0 CONTROL_PROOF_FAILED=0 CONTROL_VERDICT_BEFORE=""
        BASELINE_IMAGES="" SRC_CHECKOUT="$1" CMD_FILE="$cf"
        log() { :; }
        step() { :; }
        warn() { :; }
        ok() { :; }
        drain_harness_or_refuse() { :; }
        parent_lock_checkpoint() { :; }
        parent_lock_miner_restore() { :; }
        control_units_verdict() { echo on-target; }
        wait_bench_healthy() { return 0; }
        verify_restore_proof() { return 0; }
        chain_restore_prepare() { echo chain_restore_prepare >>"${ALL_LOG:-/dev/null}"; }
        on_bench() {
            echo "$1" >>"${ALL_LOG:-/dev/null}"
            case "$1" in
            # The source-checkout probe: answer as the fixture says, and never record it as the
            # restore command.
            "test -f "*dashboard/Dockerfile*) [ "$SRC_CHECKOUT" = yes ] && return 0 || return 1 ;;
            "cd '$RESTORE_DIR' && { "*)
                [ -s "$CMD_FILE" ] || printf '%s' "$1" >"$CMD_FILE"
                return 0
                ;;
            esac
            return 0
        }
        eval "$RESTORE_SRC"
        restore_all
    ) >/dev/null 2>&1
    cat "$cf"
    rm -f "$cf"
}

echo "== the restore command, by baseline kind =="
# The capture is the WHOLE `cd ... && ...` string, because section 2b runs it; the leading cd is
# stripped here only so the by-kind assertions below read as before.
SRC_FULL="$(drive_restore yes)"
BUNDLE_FULL="$(drive_restore no)"
SRC_CMD="${SRC_FULL#*&& }"
BUNDLE_CMD="${BUNDLE_FULL#*&& }"
assert_contains "the capture is the full command, cd included" "$SRC_FULL" "cd '/srv/code/baseline' &&"

# The fix. A source-checkout baseline shares `:dev` with the branch, so the restore must REBUILD
# from the baseline's tree. Kills the mutation that reverts the restore to `apply && up`.
assert_contains "a source-checkout baseline is restored with 'pithead upgrade'" "$SRC_CMD" "./pithead upgrade"
assert_eq "a source-checkout restore cannot fall back to apply/up" "$SRC_CMD" "{ ./pithead upgrade; }"
# A release bundle's images are versioned tags the branch never touched: rebuilding there is waste,
# and forcing it would make every release-box restore minutes longer for nothing.
assert_eq "a release-bundle baseline is NOT rebuilt" \
    "$(case "$BUNDLE_CMD" in *upgrade*) echo yes ;; *) echo no ;; esac)" "no"
assert_contains "a release-bundle baseline still gets apply + up" "$BUNDLE_CMD" "./pithead apply -y"

# --- 2b. The grouping, DRIVEN --------------------------------------------------------------------
# `cd D && upgrade || { apply && up; }` does not mean what it looks like: the `||` binds to the whole
# `cd D && upgrade`, so a FAILED cd runs the FALLBACK in the ssh session's default directory and the
# whole command still returns 0 — a restore that never entered RESTORE_DIR, reported as having run.
# The braces in e2e.sh are what prevent that. This runs the SHIPPED command string against a cd that
# cannot succeed, rather than asserting on its text: a text assertion here would pass on any string
# that happens to contain a brace.
grouping_probe() { # <full-command> -> "<rc> ran|clean"
    local sandbox cmd rc ran
    sandbox="$(mktemp -d)"
    # A `pithead` in the DEFAULT directory is the whole hazard: if the fallback runs after a failed
    # cd, this is what it would find and execute.
    printf '#!/bin/sh\nprintf %%s "$1" >>"%s/ran"\nexit 0\n' "$sandbox" >"$sandbox/pithead"
    chmod +x "$sandbox/pithead"
    cmd="$(printf '%s' "$1" | sed "s#/srv/code/baseline#$sandbox/no-such-dir#")"
    (cd "$sandbox" && eval "$cmd") >/dev/null 2>&1
    rc=$?
    [ -s "$sandbox/ran" ] && ran=ran || ran=clean
    rm -rf "$sandbox"
    printf '%s %s' "$rc" "$ran"
}

echo "== a failed cd must not run the restore anyway =="
assert_eq "a failed cd fails the restore and executes nothing" "$(grouping_probe "$SRC_FULL")" "1 clean"

assert_contains "restore calls recreation after upgrade" "$RESTORE_SRC" "recreate_test_checkout_containers"

echo "== a post-census branch recreation must not pass restoration =="
DECLARED="$BASE"
LIVE='dashboard=sha256:aaa|/baseline
monerod=sha256:mmm|/baseline
p2pool=sha256:ppp|/baseline
tor=sha256:ttt|/baseline
xmrig-proxy=sha256:xxx|/baseline'
LATE_OWNER="${LIVE/p2pool=sha256:ppp|\/baseline/p2pool=sha256:ppp|\/test}"
assert_eq "the baseline declaration and owner both match" \
    "$(grade_restore_identity "$BASE" "$LIVE" "$DECLARED" /test | grep -cv '^verified ')" "0"
assert_eq "a branch container recreated after the branch census is rejected by its owner" \
    "$(grade_restore_identity "$BASE" "$LATE_OWNER" "$DECLARED" /test | grep '^test-checkout ')" "test-checkout p2pool"
LATE_IMAGES="${LIVE/p2pool=sha256:ppp/p2pool=sha256:late}"
assert_eq "a post-census branch image is rejected against the baseline declaration" \
    "$(grade_restore_identity "$BASE" "$LATE_IMAGES" "$DECLARED" /test | grep '^wrong-image ')" "wrong-image p2pool"
assert_eq "a duplicate branch container cannot hide behind a matching baseline container" \
    "$(grade_restore_identity "$BASE" "$LIVE"$'\n'"p2pool=sha256:late|/test" "$DECLARED" /test | grep '^test-checkout ')" "test-checkout p2pool"
assert_eq "a duplicate service fails even when its labels look valid" \
    "$(grade_restore_identity "$BASE" "$LIVE"$'\n'"p2pool=sha256:ppp|/baseline" "$DECLARED" /test | grep '^duplicate ')" "duplicate p2pool"
assert_eq "a test-only service cannot escape the proof" \
    "$(grade_restore_identity "$BASE" "$LIVE"$'\n'"extra=sha256:late|/other" "$DECLARED" /test | grep '^unexpected-service ')" "unexpected-service extra"
assert_eq "an extra service label is matched literally" \
    "$(grade_restore_identity "$BASE" "$LIVE"$'\n'".*=sha256:late|/other" "$DECLARED" /test | grep '^unexpected-service ')" "unexpected-service .*"
assert_eq "an option-shaped extra label cannot bypass the proof" \
    "$(grade_restore_identity "$BASE" "$LIVE"$'\n'"--help=sha256:late|/other" "$DECLARED" /test | grep '^unexpected-service ')" "unexpected-service --help"

# Drive the full proof with the other, independent restore checks satisfied. A mutation that
# replaces verify_restore_proof's identity grader with a hardcoded pass must fail these checks.
proof_probe() { # <baseline-census> <live-census> -> verify_restore_proof exit status
    (
        BASELINE_IMAGES="$1" E2E_DIR=/test RESTORE_DIR=/baseline RESTORE_PROOF_VAR=MONERO_NODE_PASSWORD
        stack_image_census() { printf '%s\n' "$BASE"; }
        declared_image_census() { printf '%s\n' "$DECLARED"; }
        stack_restore_census() { printf '%s\n' "$PROBE_LIVE"; }
        env_bake_verdict() { echo match; }
        control_units_verdict() { echo on-target; }
        chain_restore_proof() { return 0; }
        restore_egress_boot_unit() { return 0; }
        restore_egress_check_units() { return 0; }
        ok() { :; }
        warn() { :; }
        on_bench() {
            case "$1" in
            *"cd '/baseline' && bash -s"*) echo rpc-ok ;;
            *"is-enabled pithead-control.path"*) return 0 ;;
            esac
        }
        PROBE_LIVE="$2"
        verify_restore_proof >/dev/null 2>&1
        printf '%s' "$?"
    )
}
assert_eq "the full proof accepts baseline images and owners" "$(proof_probe "$BASE" "$LIVE")" "0"
assert_eq "the full proof rejects a missing preflight image census" "$(proof_probe '' "$LIVE")" "1"
assert_eq "the full proof rejects a late test-checkout owner" "$(proof_probe "$BASE" "$LATE_OWNER")" "1"
assert_eq "the full proof rejects a late branch image" "$(proof_probe "$BASE" "$LATE_IMAGES")" "1"

census_probe() { # <service-label> -> remote census exit status
    local dir rc
    dir="$(mktemp -d)"
    cat >"$dir/docker" <<'DOCKER'
#!/usr/bin/env bash
case "$1" in
ps) printf 'container\n' ;;
inspect) case "$3" in
    *service*) printf '%s\n' "$SERVICE_LABEL" ;;
    *working_dir*) printf '/other\n' ;;
    *) printf 'sha256:%064d\n' 0 ;;
    esac ;;
esac
DOCKER
    chmod +x "$dir/docker"
    (
        export PATH="$dir:$PATH" SERVICE_LABEL="$1"
        on_bench() { bash -c "$1"; }
        stack_restore_census >/dev/null 2>&1
    )
    rc=$?
    rm -rf "$dir"
    printf '%s' "$rc"
}
assert_eq "a normal service label is accepted by the live census" "$(census_probe p2pool)" "0"
assert_eq "a newline label cannot forge a second service row" "$(census_probe $'extra\np2pool')" "1"
assert_eq "a trailing newline in a service label cannot be stripped into a valid row" \
    "$(census_probe $'p2pool\n')" "1"

echo "== recreate only late test-checkout containers =="
recreate_probe() { # [fail] [branch-service] -> command and return code
    local dir rc
    dir="$(mktemp -d)"
    mkdir "$dir/baseline" "$dir/bin"
    cat >"$dir/bin/docker" <<'DOCKER'
#!/usr/bin/env bash
case "$1 $2" in
"ps -aq") printf 'branch\nbaseline\n' ;;
"inspect --format") case "${*: -1}" in branch) printf '%s|/test\n' "$BRANCH_SERVICE" ;; baseline) printf 'monerod|/baseline\n' ;; esac ;;
"compose config") printf 'p2pool\nmonerod\n' ;;
"compose up") printf '%s\n' "$*" >"$CAPTURE"; [ "${FAIL_COMPOSE:-}" != yes ] ;;
"rm -f") printf '%s\n' "$*" >"$CAPTURE" ;;
esac
DOCKER
    chmod +x "$dir/bin/docker"
    (
        export PATH="$dir/bin:$PATH" CAPTURE="$dir/capture" FAIL_COMPOSE="${1:-}" BRANCH_SERVICE="${2:-p2pool}"
        RESTORE_DIR="$dir/baseline" E2E_DIR=/test
        on_bench() { bash -c "$1"; }
        recreate_test_checkout_containers >/dev/null
    )
    rc=$?
    printf '%s|%s' "$(cat "$dir/capture" 2>/dev/null)" "$rc"
    rm -rf "$dir"
}
assert_eq "only the late branch service is force-recreated" "$(recreate_probe)" \
    "compose up -d --no-deps --force-recreate p2pool|0"
assert_eq "a failed recreation is not a restore pass" "$(recreate_probe yes)" \
    "compose up -d --no-deps --force-recreate p2pool|1"
assert_eq "a test-only service is removed by container ID" "$(recreate_probe no extra)" "rm -f branch|0"
assert_eq "an option-shaped service label cannot become a Compose argument" \
    "$(recreate_probe no --renew-anon-volumes)" "rm -f branch|0"

# #2639: the restore converges the baseline over the branch and never runs `pithead down`, which
# stopped and recreated monerod and tari on every deploying run, however unchanged. Every command
# restore_all gives the box is recorded, for both baseline kinds.
echo "== the restore never takes the stack down (#2639) =="
for kind in yes no; do
    ALL_LOG="$(mktemp)"
    ALL_LOG="$ALL_LOG" drive_restore "$kind" >/dev/null
    assert_eq "no 'pithead down' on the restore path (source checkout: $kind)" "$(grep -c 'pithead down' "$ALL_LOG")" "0"
    assert_eq "the restore prepares the chain record first (source checkout: $kind)" "$(head -n1 "$ALL_LOG")" "chain_restore_prepare"
    rm -f "$ALL_LOG"
done

# --check deploys nothing and borrows nothing, so restore_all has nothing to put back — and an
# outer restore would mutate a bench this mode promised only to read.
assert_eq "restore_all is a no-op in --check mode" "$(drive_restore no check)" ""

# --- #2460: the egress boot unit goes back the way the run found it ------------------------------
# A model bench: UNIT is the unit's state; the removal command clears it unless STICKY=1. Prints
# "<rc> <unit after> <removal commands sent>".
egress_restore() { # <before> <unit now> [sticky]
    (
        EGRESS_UNIT_BEFORE="$1" UNIT="$2" STICKY="${3:-0}" removals=0
        ok() { :; }
        warn() { :; }
        step() { printf 'step:%s\n' "$1" >&2; }
        on_bench() {
            case "$1" in
            *"disable --now"*)
                removals=$((removals + 1))
                [ "$STICKY" = 1 ] || UNIT=absent
                ;;
            *"systemctl cat"*) echo "$UNIT" ;;
            *"show -p Wants"*) [ "$UNIT" = absent ] ;;
            esac
        }
        restore_egress_boot_unit
        echo "$? $UNIT $removals"
    )
}
assert_eq "a unit this run added is removed, and the absence proven" "$(egress_restore absent present)" "0 absent 1"
assert_eq "a unit the baseline already had is left alone" "$(egress_restore present present)" "0 present 0"
assert_contains "and the restore says so, so a leftover from a cancelled run is visible" \
    "$(egress_restore present present 2>&1 >/dev/null)" "already on the bench before this run"
assert_eq "a unit that survives the removal fails the restore proof" "$(egress_restore absent present 1)" "1 present 1"
assert_eq "an unrecorded baseline fails closed and removes nothing" "$(egress_restore "" present)" "1 present 0"
assert_contains "verify_restore_proof runs the egress unit restore" "$(declare -f verify_restore_proof)" "restore_egress_boot_unit"
assert_contains "e2e.sh records the unit before deploy_branch installs it" "$(cat "$E2E_SRC")" 'EGRESS_UNIT_BEFORE="$(egress_boot_unit_state)"'

# --- #2599: the egress check pair goes back the same way ------------------------------------------
check_restore() { # <before> <units now> [sticky] -> "<rc> <units after> <removal commands sent>"
    (
        EGRESS_CHECK_BEFORE="$1" UNITS="$2" STICKY="${3:-0}" removals=0
        ok() { :; }
        warn() { :; }
        on_bench() {
            case "$1" in
            *"disable --now pithead-egress.timer"*)
                removals=$((removals + 1))
                [ "$STICKY" = 1 ] || UNITS=absent
                ;;
            *"systemctl cat pithead-egress"*) echo "$UNITS" ;;
            esac
        }
        restore_egress_check_units
        echo "$? $UNITS $removals"
    )
}
assert_eq "a check pair this run added is removed, and the absence proven" "$(check_restore absent present)" "0 absent 1"
assert_eq "a check pair the baseline already had is left alone" "$(check_restore present present)" "0 present 0"
assert_eq "a check pair that survives the removal fails the restore proof" "$(check_restore absent present 1)" "1 present 1"
assert_eq "an unrecorded baseline fails closed and removes nothing" "$(check_restore "" present)" "1 present 0"
assert_contains "verify_restore_proof runs the check pair restore" "$(declare -f verify_restore_proof)" "restore_egress_check_units"
assert_contains "e2e.sh records the timer before deploy_branch installs it" "$(cat "$E2E_SRC")" 'EGRESS_CHECK_BEFORE="$(egress_boot_unit_state pithead-egress.timer)"'

echo ""
printf 'restore-proof self-test: %s passed, %s failed\n' "$IT_PASS" "$IT_FAIL"
[ "$IT_FAIL" -eq 0 ]
