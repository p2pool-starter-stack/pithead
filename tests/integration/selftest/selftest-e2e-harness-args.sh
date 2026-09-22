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
# selftest-e2e-boundary.sh; this file only proves run_harness appends whatever it is handed.
launch_of() { # <harness-phase-args> -> the raw launch command string
    local lf sf
    lf="$(mktemp)" sf="$(mktemp)"
    # shellcheck disable=SC2034,SC2329
    (
        exec </dev/null
        MODE=targeted BORROW_MINER=0 WORKERS=1 BENCH_HOST=bench E2E_DIR=/srv/code/pithead-e2e RESTORE_DIR=/srv/code/pithead-live
        SCENARIO="" RIGFORGE_BOOTSTRAP_VERSION="" HARNESS_PHASE_ARGS="$1" ROTATE_FIXTURE_ATTESTATION=""
        REMOTE_NODE_ARGS=() REMOTE_NODE_HOSTS=()
        LAUNCH_FILE="$lf" STDIN_FILE="$sf"
        log() { :; }
        step() { :; }
        warn() { :; }
        ok() { :; }
        die() { exit 1; }
        harness_prepare() { HARNESS_STATE=/test/state; }
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

echo "== --harness-arg lands AFTER the mode's own flags, unchanged (#2179) =="
BASE="$(phase_list_of "$(launch_of "")")"
WITH_ARG="$(phase_list_of "$(launch_of " --hardening")")"
assert_eq "targeted's own phases are unaffected by an empty HARNESS_PHASE_ARGS" \
    "$(has_phase "$BASE" --hardening)" "no"
assert_eq "a supplied phase joins the launch" "$(has_phase "$WITH_ARG" --hardening)" "yes"
assert_eq "it lands strictly AFTER the mode's own flags, not before" \
    "$(printf '%s\n' "$WITH_ARG" | grep -oE -- '--(lifecycle|hardening)' | tr '\n' ' ')" \
    "--lifecycle --hardening "
assert_eq "a --scenario NAME pair supplied by validate_harness_args reaches run.sh verbatim" \
    "$(has_phase "$(phase_list_of "$(launch_of " --scenario custom-name")")" custom-name)" "yes"

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
    '[ "$1" = render ]' \
    'dir=$(jq -r .tor.data_dir config.json)' \
    'sed -e "s|^TOR_DATA_DIR=.*|TOR_DATA_DIR=$dir|" -e "s|^DASHBOARD_ONION_CLIENT_PUBKEY=.*|DASHBOARD_ONION_CLIENT_PUBKEY=fixture-public|" -e "s|^DASHBOARD_ONION_CLIENT_PRIVKEY=.*|DASHBOARD_ONION_CLIENT_PRIVKEY=fixture-private|" .env >.env.test' \
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
            compose)
                tor_dir=$(jq -r .tor.data_dir config.json)
                for svc in p2pool dashboard monero tari; do
                    mkdir -p "$tor_dir/$svc"
                    char=a
                    case "$svc" in dashboard) char=b ;; monero) char=c ;; tari) char=d ;; esac
                    value=
                    i=0
                    while [ "$i" -lt 56 ]; do value="$value$char"; i=$((i + 1)); done
                    printf "%s.onion\n" "$value" >"$tor_dir/$svc/hostname"
                    printf "fixture-%s-secret\n" "$svc" >"$tor_dir/$svc/hs_ed25519_secret_key"
                    printf "fixture-%s-public\n" "$svc" >"$tor_dir/$svc/hs_ed25519_public_key"
                done
                ;;
            exec)
                path="$4"
                if [ "$3" = test ]; then path="$5"; fi
                svc=$(basename "$(dirname "$path")")
                tor_dir=$(jq -r .tor.data_dir config.json)
                case "$3" in test) test -f "$tor_dir/$svc/hostname" ;; cat) cat "$tor_dir/$svc/hostname" ;; esac
                ;;
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
mkdir -p "$E2E_DIR/backups"
printf 'fixture-client-credential\n' >"$E2E_DIR/backups/rotate-onion-env-preserve"
chmod 600 "$E2E_DIR/backups/rotate-onion-env-preserve"
if cleanup_rotate_onion_fixture && [ -z "$ROTATE_FIXTURE_DIR" ] && [ ! -e "$fixture" ] &&
    [ ! -e "$fixture.attestation" ] && [ ! -e "$E2E_DIR/backups/rotate-onion-env-preserve" ]; then
    it_pass "fixture cleanup removes Tor data, marker, and credential snapshot"
else
    it_fail "fixture cleanup removes Tor data, marker, and credential snapshot"
fi

echo ""
echo "selftest-e2e-harness-args: $IT_PASS passed, $IT_FAIL failed"
[ "$IT_FAIL" -eq 0 ] || exit 1
