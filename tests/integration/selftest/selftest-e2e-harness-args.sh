#!/usr/bin/env bash
# Self-test e2e.sh's --harness-arg (#2179): bench-ci#46 forwards one hand-picked run.sh phase this
# way. Standalone, same reasoning as selftest-e2e-phases.sh — kept off selftest-e2e-phases.sh's own
# file-budget ceiling. Run directly, or via `make test-integration-selftest`. No server, no bench.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=tests/integration/lib.sh
source "$HERE/../lib.sh"
# shellcheck source=tests/integration/lib/detached-harness.sh  # run_harness's REAL collaborators
source "$HERE/../lib/detached-harness.sh"
E2E_SRC="$HERE/../e2e.sh"

HARNESS_SRC="$(sed -n '/^run_harness() {$/,/^}$/p' "$E2E_SRC")"
assert_eq "the extraction is the whole function (opens and closes)" \
    "$(printf '%s\n' "$HARNESS_SRC" | sed -n '1p;$p' | tr '\n' ' ')" "run_harness() { } "

# Drives run_harness with HARNESS_PHASE_ARGS set directly, the way validate_harness_args
# (lib/harness-args.sh) would leave it — that function's OWN allowlist/quoting is covered by
# selftest-e2e-boundary.sh; this file proves what run_harness launches with what it is handed.
launch_of() { # <harness-phase-args> [borrow-miner] [mode] [scenario] [harness-scenario-args] -> the raw launch command string
    local lf sf
    lf="$(mktemp)" sf="$(mktemp)"
    # shellcheck disable=SC2034,SC2329
    (
        exec </dev/null
        MODE="${3:-targeted}" BORROW_MINER="${2:-0}" WORKERS=1 BENCH_HOST=bench E2E_DIR=/srv/code/pithead-e2e RESTORE_DIR=/srv/code/pithead-live
        SCENARIO="${4:-}" RIGFORGE_BOOTSTRAP_VERSION="" HARNESS_PHASE_ARGS="$1" HARNESS_SCENARIO_ARGS="${5:-}" ROTATE_FIXTURE_ATTESTATION=""
        REMOTE_NODE_ARGS=() REMOTE_NODE_HOSTS=()
        LAUNCH_FILE="$lf" STDIN_FILE="$sf"
        log() { :; }
        step() { :; }
        warn() { :; }
        ok() { :; }
        die() { exit 1; }
        harness_prepare() { HARNESS_STATE=/test/state; }
        rig_supply() { RIG_NAME=rig-a RIG_HOST="" RIG_CONTROL_PORT=""; }
        harness_finished() { :; }
        on_bench() {
            case "$1" in
            *nohup*)
                printf '%s' "$1" >"$LAUNCH_FILE"
                cat >"$STDIN_FILE"
                echo 4242
                ;;
            *e2e-harness.done*)
                echo 0
                return 0
                ;;
            esac
            return 0
        }
        eval "$HARNESS_SRC"
        run_harness >/dev/null 2>&1
        :
    ) </dev/null
    cat "$lf"
    rm -f "$lf" "$sf"
}

has_phase() { # <phase-list> <flag> -> "yes" | "no"
    case " $1 " in *" $2 "*) echo yes ;; *) echo no ;; esac
}

phase_list_of() { # <launch-cmd> -> the phase list run.sh was launched with
    printf '%s\n' "$1" | sed -n 's/.*\.e2e-run\.sh[^ ]* [^ ]* [^ ]* [^ ]* [^ ]* [^ ]* [^ ]* [^ ]* \(.*\) >\/dev\/null.*/\1/p'
}

echo "== hand-picked phases replace the preset, keeping its setup (#2179, bench-ci#878) =="
BASE="$(phase_list_of "$(launch_of "")")"
WITH_ARG="$(phase_list_of "$(launch_of " --hardening")")"
assert_eq "targeted's own phases are unaffected by an empty HARNESS_PHASE_ARGS" \
    "$(has_phase "$BASE" --lifecycle)|$(has_phase "$BASE" --auth-fail-closed)|$(has_phase "$BASE" --hardening)" "yes|yes|no"
assert_eq "a supplied phase joins the launch" "$(has_phase "$WITH_ARG" --hardening)" "yes"
assert_eq "it replaces the preset's phases, so none of them can skip it" \
    "$(has_phase "$WITH_ARG" --lifecycle)|$(has_phase "$WITH_ARG" --auth-fail-closed)" "no|no"
assert_eq "the preset's scenario stays, or run.sh would sweep the whole matrix" \
    "$(has_phase "$WITH_ARG" local-pruned-main-secure-tari)" "yes"
RIG_BASE="$(phase_list_of "$(launch_of "" 1)")"
RIG_ARG="$(phase_list_of "$(launch_of " --hardening" 1)")"
RIG_PICK="$(phase_list_of "$(launch_of " --rigforge-control" 1)")"
assert_eq "a borrowed rig adds the rig phases to a preset run" \
    "$(has_phase "$RIG_BASE" --rigforge)|$(has_phase "$RIG_BASE" --rigforge-control)" "yes|yes"
assert_eq "a hand-picked run drops the unrequested rig phases but keeps the rig identity" \
    "$(has_phase "$RIG_ARG" --rigforge)|$(has_phase "$RIG_ARG" --rigforge-control)|$(has_phase "$RIG_ARG" rig-a)|$(has_phase "$RIG_ARG" --hardening)" \
    "no|no|yes|yes"
assert_eq "a hand-picked rig phase runs, once" \
    "$(printf '%s\n' "$RIG_PICK" | grep -o -- '--rigforge-control' | wc -l | tr -d ' ')" "1"
assert_eq "a --scenario NAME pair supplied by validate_harness_args reaches run.sh verbatim" \
    "$(has_phase "$(phase_list_of "$(launch_of "" 0 targeted "" " --scenario custom-name")")" custom-name)" "yes"
RIG_SCENARIO="$(phase_list_of "$(launch_of "" 1 targeted "" " --scenario custom-name")")"
assert_eq "a scenario-only modifier keeps targeted and borrowed-rig phases" \
    "$(has_phase "$RIG_SCENARIO" --auth-fail-closed)|$(has_phase "$RIG_SCENARIO" --lifecycle)|$(has_phase "$RIG_SCENARIO" --rigforge)|$(has_phase "$RIG_SCENARIO" --rigforge-control)|$(has_phase "$RIG_SCENARIO" custom-name)" \
    "yes|yes|yes|yes|yes"
MATRIX_BASE="$(phase_list_of "$(launch_of "" 0 matrix local-pruned-main-secure-tari)")"
MATRIX_ARG="$(phase_list_of "$(launch_of " --hardening" 0 matrix local-pruned-main-secure-tari)")"
MATRIX_SCENARIO="$(phase_list_of "$(launch_of "" 1 matrix "" " --scenario custom-name")")"
assert_eq "matrix keeps its preset without a hand-picked phase" \
    "$(has_phase "$MATRIX_BASE" --safety-backup)|$(has_phase "$MATRIX_BASE" --lifecycle)|$(has_phase "$MATRIX_BASE" --auth-fail-closed)" "yes|yes|yes"
assert_eq "a hand-picked matrix phase replaces its preset but keeps the scenario" \
    "$(has_phase "$MATRIX_ARG" --hardening)|$(has_phase "$MATRIX_ARG" --lifecycle)|$(has_phase "$MATRIX_ARG" --fault-injection)|$(has_phase "$MATRIX_ARG" --auth-fail-closed)|$(has_phase "$MATRIX_ARG" --subnet)|$(has_phase "$MATRIX_ARG" --safety-backup)|$(has_phase "$MATRIX_ARG" local-pruned-main-secure-tari)" \
    "yes|no|no|no|no|no|yes"
assert_eq "a scenario-only modifier keeps matrix and borrowed-rig phases" \
    "$(has_phase "$MATRIX_SCENARIO" --safety-backup)|$(has_phase "$MATRIX_SCENARIO" --lifecycle)|$(has_phase "$MATRIX_SCENARIO" --rigforge)|$(has_phase "$MATRIX_SCENARIO" --rigforge-control)|$(has_phase "$MATRIX_SCENARIO" custom-name)" \
    "yes|yes|yes|yes|yes"

echo "== fixture mutation follows the chain snapshot, and cleanup follows baseline convergence =="
DEPLOY_SRC="$(sed -n '/^deploy_branch() {$/,/^}$/p' "$E2E_SRC")"
assert_eq "the deploy extraction is the whole function" \
    "$(printf '%s\n' "$DEPLOY_SRC" | sed -n '1p;$p' | tr '\n' ' ')" "deploy_branch() { } "
DEPLOY_ORDER="$({
    # shellcheck disable=SC2034 # consumed by the eval'd deploy_branch
    BENCH_HOST=bench E2E_DIR=/srv/code/pithead-e2e
    parent_lock_checkpoint() { :; }
    prepare_rotate_onion_fixture() { echo prepare; }
    deploy_keeping_chain() { echo deploy; }
    bootstrap_rotate_onion_fixture() { echo bootstrap; }
    log() { :; }
    on_bench() { :; }
    step() { :; }
    wait_bench_healthy() { :; }
    wait_synced() { :; }
    warn() { :; }
    ok() { :; }
    die() { return 1; }
    eval "$DEPLOY_SRC"
    deploy_branch
})"
assert_eq "fixture preparation precedes the deploy, but identity minting follows its chain snapshot" \
    "$DEPLOY_ORDER" "$(printf 'prepare\ndeploy\nbootstrap')"

RESTORE_SRC="$(sed -n '/^restore_all() {$/,/^}$/p' "$E2E_SRC")"
assert_eq "the restore extraction is the whole function" \
    "$(printf '%s\n' "$RESTORE_SRC" | sed -n '1p;$p' | tr '\n' ' ')" "restore_all() { } "
assert_eq "fixture cleanup follows the baseline convergence command" \
    "$(printf '%s\n' "$RESTORE_SRC" | awk '/if on_bench .*restore_cmd/{converged=1} /cleanup_rotate_onion_fixture/{print converged ? "after" : "before"}')" after
assert_eq "restore does not blanket-stop the baseline stack" \
    "$(printf '%s\n' "$RESTORE_SRC" | grep -Eq 'on_bench .*([.]/pithead|docker compose) down' && echo yes || echo no)" no

if (
    # shellcheck source=tests/integration/lib/harness-args.sh
    source "$HERE/../lib/harness-args.sh"
    MODE=targeted KEEP=0 HARNESS_ARGS=(--rotate-onion)
    die() { return 1; }
    validate_harness_args && [ "$HARNESS_PHASE_ARGS" = " --rotate-onion" ] &&
        [ "$ROTATE_FIXTURE_REQUIRED" = 1 ] && [ -z "$ROTATE_FIXTURE_ATTESTATION" ]
); then
    it_pass "the launcher requires an isolated fixture before rotate-onion can run"
else
    it_fail "the launcher requires an isolated fixture before rotate-onion can run"
fi

echo "== rotate-onion gets a one-run Tor fixture, not the baseline dashboard identity =="
WORK="$(cd "$(mktemp -d)" && pwd -P)"
trap 'rm -rf "$WORK"' EXIT
E2E_DIR="$WORK/e2e"
SOURCE_TOR="$WORK/live-tor"
mkdir -p "$E2E_DIR/data" "$SOURCE_TOR/p2pool"
printf '{"dashboard":{"onion":{"enabled":false,"client_auth":false}},"tor":{"data_dir":"auto"}}\n' >"$E2E_DIR/config.json"
printf '%s\n' \
    "TOR_DATA_DIR=$SOURCE_TOR" \
    'COMPOSE_PROFILES=local_node,local_tari' \
    'P2POOL_ONION_ADDRESS=live-p2pool.onion' \
    'MONERO_ONION_ADDRESS=live-monero.onion' \
    'TARI_ONION_ADDRESS=live-tari.onion' \
    'DASHBOARD_ONION_ADDRESS=live.onion' \
    'DASHBOARD_ONION_CLIENT_PUBKEY=live-public' \
    'DASHBOARD_ONION_CLIENT_PRIVKEY=live-private' >"$E2E_DIR/.env"
printf 'production-identity-must-not-move\n' >"$SOURCE_TOR/p2pool/hostname"
printf 'production-secret-must-not-move\n' >"$SOURCE_TOR/p2pool/hs_ed25519_secret_key"
printf 'production-public-must-not-move\n' >"$SOURCE_TOR/p2pool/hs_ed25519_public_key"
printf '%s\n' '#!/bin/sh' \
    'set -e' \
    'printf "%s\n" "$*" >>.pithead-calls' \
    'dir=$(jq -r .tor.data_dir config.json)' \
    'case "$1" in' \
    'render) sed "s|^TOR_DATA_DIR=.*|TOR_DATA_DIR=$dir|" .env >.env.test ;;' \
    'rotate-dashboard-onion)' \
    '    [ "$2" = -y ]' \
    '    for svc in p2pool dashboard monero tari; do' \
    '        mkdir -p "$dir/$svc"' \
    '        char=a; case "$svc" in dashboard) char=b ;; monero) char=c ;; tari) char=d ;; esac' \
    '        address=$(printf "%056d" 0 | tr 0 "$char").onion' \
    '        case "$svc" in p2pool) p2pool=$address ;; dashboard) dashboard=$address ;; monero) monero=$address ;; tari) tari=$address ;; esac' \
    '        printf "%s\n" "$address" >"$dir/$svc/hostname"' \
    '        printf "fixture-%s-secret\n" "$svc" >"$dir/$svc/hs_ed25519_secret_key"' \
    '        printf "fixture-%s-public\n" "$svc" >"$dir/$svc/hs_ed25519_public_key"' \
    '    done' \
    '    sed -e "s|^P2POOL_ONION_ADDRESS=.*|P2POOL_ONION_ADDRESS=$p2pool|" -e "s|^MONERO_ONION_ADDRESS=.*|MONERO_ONION_ADDRESS=$monero|" -e "s|^TARI_ONION_ADDRESS=.*|TARI_ONION_ADDRESS=$tari|" -e "s|^DASHBOARD_ONION_ADDRESS=.*|DASHBOARD_ONION_ADDRESS=$dashboard|" -e "s|^DASHBOARD_ONION_CLIENT_PUBKEY=.*|DASHBOARD_ONION_CLIENT_PUBKEY=fixture-public|" -e "s|^DASHBOARD_ONION_CLIENT_PRIVKEY=.*|DASHBOARD_ONION_CLIENT_PRIVKEY=fixture-private|" .env >.env.test' \
    '    ;;' \
    '*) exit 1 ;;' \
    'esac' \
    'mv .env.test .env' >"$E2E_DIR/pithead"
chmod +x "$E2E_DIR/pithead"
chmod 600 "$E2E_DIR/config.json" "$E2E_DIR/.env"
on_bench() {
    SNIPPET="$1" bash -c '
        readlink() { [ "$1" = -f ] && shift; [ "$1" = -- ] && shift; (cd "$1" && pwd -P); }
        sudo() {
            [ "$1" = -n ] && shift
            [ "$1" = chown ] && return 0
            if [ "$1" = rm ] && [ "$2" = -rf ] && [ "$3" = --one-file-system ]; then shift 3; command rm -rf "$@"; return; fi
            "$@"
        }
        docker() {
            case "$1" in
            ps)
                [ "$DOCKER_PS_FAIL" != 1 ] || return 1
                [ "$2" = -aq ] && [ "$#" = 2 ] || return 1
                if [ "$DOCKER_INSPECT_FIRST_FAIL" = 1 ]; then
                    printf "first-container\nsecond-container\n"
                elif [ -n "$MOUNTED_FIXTURE" ]; then
                    printf "fixture-container\n"
                fi
                ;;
            inspect)
                [ "$DOCKER_INSPECT_FAIL" != 1 ] || return 1
                [ "$DOCKER_INSPECT_FIRST_FAIL" != 1 ] || [ "$4" != first-container ] || return 1
                printf "%s\n" "$MOUNTED_FIXTURE"
                ;;
            esac
        }
        eval "$SNIPPET"
    '
}
# shellcheck source=tests/integration/lib/harness-args.sh
source "$HERE/../lib/harness-args.sh"
ROTATE_FIXTURE_REQUIRED=1 ROTATE_FIXTURE_DIR="" ROTATE_FIXTURE_ATTESTATION=""
if prepare_rotate_onion_fixture && bootstrap_rotate_onion_fixture &&
    [ "$ROTATE_FIXTURE_ATTESTATION" = "$ROTATE_FIXTURE_DIR" ] &&
    [ "$(cat "$SOURCE_TOR/p2pool/hostname")" = production-identity-must-not-move ] &&
    [ "$(cat "$SOURCE_TOR/p2pool/hs_ed25519_secret_key")" = production-secret-must-not-move ] &&
    [ -f "$ROTATE_FIXTURE_DIR/p2pool/hs_ed25519_secret_key" ] &&
    ! grep -R -q 'production-.*-must-not-move' "$ROTATE_FIXTURE_DIR" &&
    [ "$(cat "$E2E_DIR/.pithead-calls")" = "$(printf 'render\nrotate-dashboard-onion -y')" ] &&
    [ "$(jq -r '.dashboard.onion.enabled, .dashboard.onion.client_auth, .tor.data_dir' "$E2E_DIR/config.json")" = "$(printf 'true\ntrue\n%s' "$ROTATE_FIXTURE_DIR")" ] &&
    [ "$(awk -F= '$1 == "TOR_DATA_DIR" { print $2 }' "$E2E_DIR/.env")" = "$ROTATE_FIXTURE_DIR" ] &&
    [ "$(grep -c '=placeholder$' "$E2E_DIR/.env")" = 0 ] &&
    [ "$(cat "$ROTATE_FIXTURE_DIR.attestation")" = "$ROTATE_FIXTURE_DIR" ]; then
    it_pass "fixture provisioning mints test-only dashboard and mining identities"
else
    it_fail "fixture provisioning mints test-only dashboard and mining identities"
fi
fixture="$ROTATE_FIXTURE_DIR"
export MOUNTED_FIXTURE="$fixture"
if ! cleanup_rotate_onion_fixture && [ -d "$fixture" ]; then
    it_pass "fixture cleanup refuses an exact active mount"
else
    it_fail "fixture cleanup refuses an exact active mount"
fi
export MOUNTED_FIXTURE="$fixture/child"
if ! cleanup_rotate_onion_fixture && [ -d "$fixture" ]; then
    it_pass "fixture cleanup refuses a descendant active mount"
else
    it_fail "fixture cleanup refuses a descendant active mount"
fi
export MOUNTED_FIXTURE="$E2E_DIR/data"
if ! cleanup_rotate_onion_fixture && [ -d "$fixture" ]; then
    it_pass "fixture cleanup refuses a containing active mount"
else
    it_fail "fixture cleanup refuses a containing active mount"
fi
unset MOUNTED_FIXTURE
export DOCKER_PS_FAIL=1
if ! cleanup_rotate_onion_fixture && [ -d "$fixture" ]; then
    it_pass "fixture cleanup fails closed when the container census fails"
else
    it_fail "fixture cleanup fails closed when the container census fails"
fi
unset DOCKER_PS_FAIL
export MOUNTED_FIXTURE="$fixture" DOCKER_INSPECT_FIRST_FAIL=1
if ! cleanup_rotate_onion_fixture && [ -d "$fixture" ]; then
    it_pass "fixture cleanup fails closed when an early inspection fails before a later success"
else
    it_fail "fixture cleanup fails closed when an early inspection fails before a later success"
fi
unset DOCKER_INSPECT_FIRST_FAIL
unset MOUNTED_FIXTURE
mkdir -p "$E2E_DIR/backups/rotate-onion-identity-preserve"
printf 'saved-hidden-service-key\n' >"$E2E_DIR/backups/rotate-onion-identity-preserve/hs_ed25519_secret_key"
if ! cleanup_rotate_onion_fixture && [ -d "$fixture" ] && [ -e "$fixture.attestation" ]; then
    it_pass "fixture cleanup preserves the host-only onion identity recovery directory"
else
    it_fail "fixture cleanup preserves the host-only onion identity recovery directory"
fi
rm -rf "$E2E_DIR/backups/rotate-onion-identity-preserve"
printf 'fixture-client-credential\n' >"$E2E_DIR/backups/rotate-onion-env-preserve"
chmod 600 "$E2E_DIR/backups/rotate-onion-env-preserve"
if ! cleanup_rotate_onion_fixture && [ -d "$fixture" ] && [ -e "$fixture.attestation" ] &&
    [ -f "$E2E_DIR/backups/rotate-onion-env-preserve" ]; then
    it_pass "fixture cleanup preserves an owner-only client credential recovery snapshot"
else
    it_fail "fixture cleanup preserves an owner-only client credential recovery snapshot"
fi
rm -f "$E2E_DIR/backups/rotate-onion-env-preserve"
if cleanup_rotate_onion_fixture && [ -z "$ROTATE_FIXTURE_DIR" ] && [ ! -e "$fixture" ] &&
    [ ! -e "$fixture.attestation" ]; then
    it_pass "fixture cleanup removes Tor data and marker after phase recovery copies are gone"
else
    it_fail "fixture cleanup removes Tor data and marker after phase recovery copies are gone"
fi

echo ""
echo "selftest-e2e-harness-args: $IT_PASS passed, $IT_FAIL failed"
[ "$IT_FAIL" -eq 0 ] || exit 1
