#!/usr/bin/env bash
# The image-upgrade gate's post-upgrade comparisons (#2057, job 158 on a832bc1d): signed pins and
# inspected refs compare by name and digest, and a baseline whose data lives inside its own
# version dir is refused before the stack stops.
set -euo pipefail

SELF="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HERE="$SELF/.."
# shellcheck source=tests/integration/lib.sh
source "$HERE/lib.sh"
# shellcheck source=tests/integration/lib/live-gates.sh
source "$HERE/lib/live-gates.sh"

d1="sha256:$(printf '1%.0s' {1..64})" d2="sha256:$(printf '2%.0s' {1..64})"

echo "== a pinned tag@digest and the engine's bare digest are the same ref =="
pinned="tor reg.test:5000/pithead/pithead-tor:2.0.0@$d1
caddy caddy:2.11.4@$d2
docker-proxy tecnativa/docker-socket-proxy:v0.5.0@$d2"
running="caddy docker.io/library/caddy@$d2
docker-proxy docker.io/tecnativa/docker-socket-proxy@$d2
tor reg.test:5000/pithead/pithead-tor@$d1"
[ "$(canonical_refs "$pinned")" = "$(canonical_refs "$running")" ]

echo "== a different digest, name or registry still differs =="
[ "$(canonical_refs "tor reg.test:5000/pithead/pithead-tor@$d2")" != "$(canonical_refs "tor reg.test:5000/pithead/pithead-tor:2.0.0@$d1")" ]
[ "$(canonical_refs "tor reg.test:5000/pithead/pithead-p2pool@$d1")" != "$(canonical_refs "tor reg.test:5000/pithead/pithead-tor@$d1")" ]
[ "$(canonical_refs "tor other.test/pithead/pithead-tor@$d1")" != "$(canonical_refs "tor reg.test:5000/pithead/pithead-tor@$d1")" ]

echo "== a registry port is never mistaken for a tag =="
[ "$(canonical_refs "tor reg.test:5000/pithead-tor@$d1")" = "tor reg.test:5000/pithead-tor@$d1" ]

td="$(mktemp -d)"
trap 'rm -rf "$td"' EXIT
IT_MODE=local
IT_REMOTE_DIR="$td/pithead-v1.20.0"
mkdir -p "$IT_REMOTE_DIR/data/tor" "$td/data/monero"

echo "== data inside the version dir is named, variable by variable =="
printf 'MONERO_DATA_DIR=%s\nTOR_DATA_DIR=%s\nTARI_DATA_DIR=\n' "$td/data/monero" "$IT_REMOTE_DIR/data/tor" >"$IT_REMOTE_DIR/.env"
[ "$(data_dirs_inside_install "$IT_REMOTE_DIR")" = TOR_DATA_DIR ]

echo "== a path reaching the version dir through a symlink is still inside it =="
ln -s pithead-v1.20.0 "$td/current"
printf 'P2POOL_DATA_DIR=%s\n' "$td/current/data/tor" >"$IT_REMOTE_DIR/.env"
[ "$(data_dirs_inside_install "$IT_REMOTE_DIR")" = P2POOL_DATA_DIR ]

echo "== a shared root beside the version dirs passes, including a sibling-prefix name =="
mkdir -p "$td/pithead-v1.20.0-data"
printf 'MONERO_DATA_DIR=%s\nDASHBOARD_DATA_DIR=%s\n' "$td/data/monero" "$td/pithead-v1.20.0-data" >"$IT_REMOTE_DIR/.env"
[ -z "$(data_dirs_inside_install "$IT_REMOTE_DIR")" ]

echo "== lost durable rows are named by category and count, never by row hash =="
before=$'blocks -\nblocks aaa\nblocks bbb\nhistory ccc\nkv_store-stable ddd\npayouts -'
after=$'blocks -\nblocks aaa\nhistory zzz\nkv_store-stable ddd\npayouts -\nblocks new'
[ "$(telemetry_rows_lost "$before" "$after")" = "blocks:1,history:1" ]
[ -z "$(telemetry_rows_lost "$before" "$before"$'\nextra eee')" ]
! telemetry_rows_lost "$before" "$after" | grep -q 'bbb\|ccc' || exit 1

echo "== a failed exact restore names every check that differed =="
grep -Fq '"differs:$failed; recovery' "$HERE/lib/live-upgrade-support.sh"
! grep -q 'failed=1' <(sed -n '/^restore_upgrade_baseline()/,/^}/p' "$HERE/lib/live-upgrade-support.sh") || exit 1
[ "$(sed -n '/^restore_upgrade_baseline()/,/^}/p' "$HERE/lib/live-upgrade-support.sh" | grep -c 'failed+=" ')" = 22 ]

echo "== a recreated dashboard may rewrite a volatile key's shape, never drop the key or a stable value (#2421) =="
b=$'blocks -\nkv_store-key k1\nkv_store-key k2\nkv_store-stable s1\nkv_store-volatile-shape:snapshot_latest_data v1'
telemetry_rows_continue "$b" "${b/v1/v2}"
[ -z "$(telemetry_rows_lost "$b" "${b/v1/v2}")" ]
! telemetry_rows_continue "$b" "${b/kv_store-key k2/}" || exit 1
! telemetry_rows_continue "$b" "${b/s1/s9}" || exit 1
[ "$(telemetry_rows_lost "$b" "${b/kv_store-key k2/}")" = "kv_store-key:1" ]
python3 "$HERE/lib/migration-state-probe.py" --self-test

echo "== a restored baseline that will not start names the step that stopped it =="
(
    stack_cli_has() { :; }
    reset_control_units_for_render() { :; }
    pithead() { :; }
    baseline_up() { [ "${STOP_AT:-}" != up ]; }
    wait_status_ok() { [ "${STOP_AT:-}" != status ]; }
    wait_for() { [ "${STOP_AT:-}" != worker-set ]; }
    wait_miner_running() { [ "${STOP_AT:-}" != mining ]; }
    wait_stratum_hashes() { :; }
    start_restored_baseline && [ -z "$BASELINE_START_STEP" ]
    for STOP_AT in up status worker-set mining; do
        ! start_restored_baseline && [ "$BASELINE_START_STEP" = "$STOP_AT" ] || exit 1
    done
    grep -Fq 'failed+=" start:$BASELINE_START_STEP${BASELINE_START_ERROR:+ [$BASELINE_START_ERROR]}"' "$HERE/lib/live-upgrade-support.sh"
    # A failing render keeps its own [ERROR] line: colour stripped, secrets redacted.
    pithead() {
        printf 'noise\n\033[0;31m[ERROR]\033[0m bad value MONERO_WALLET_ADDRESS=4abc\n'
        return 1
    }
    STOP_AT=""
    ! start_restored_baseline && [ "$BASELINE_START_STEP" = render ] || exit 1
    [ "$BASELINE_START_ERROR" = "[ERROR] bad value MONERO_WALLET_ADDRESS=<redacted>" ] || exit 1
    # A path or host the error interpolates never reaches the public verdict.
    pithead() {
        printf '[ERROR] Refusing to use %s as a data directory\n' "'/srv/pithead-data' — it's a system"
        return 1
    }
    ! start_restored_baseline && [ "$BASELINE_START_ERROR" = "[ERROR] Refusing to use" ] || exit 1
    pithead() {
        printf '[ERROR] monero.remote.host is not a valid host. Got "node.home.lan:18081"\n'
        return 1
    }
    ! start_restored_baseline && [ "$BASELINE_START_ERROR" = "[ERROR] monero.remote.host is not a valid host. Got" ] || exit 1
    # baseline_up runs in this shell, so its counted skip survives a captured step.
    pithead() { :; }
    baseline_up() { UP_RAN_HERE=1; }
    UP_RAN_HERE=0
    start_restored_baseline && [ "$UP_RAN_HERE" = 1 ] && [ -z "$BASELINE_START_ERROR" ] || exit 1
)

echo "== a pre-control-runner baseline removes the units the upgraded release installed =="
(
    IT_MODE=local IT_REMOTE_DIR="$td/base"
    mkdir -p "$td/base" "$td/cand" "$td/units"
    # v1.20.0-shaped: errexit on source, no control_unit_dir.
    printf 'set -Eeuo pipefail\nstack_up() { :; }\n' >"$td/base/pithead"
    printf 'control_unit_dir() { printf %%s %q; }\n' "$td/units" >"$td/cand/pithead"
    export SUDO_LOG="$td/sudo.log"
    sudo() { printf '%s\n' "$*" >>"$SUDO_LOG"; }
    export -f sudo
    reset_control_units_for_render "$td/cand"
    [ "$(head -n1 "$td/sudo.log")" = "-n systemctl disable --now pithead-control.path" ]
    grep -Fqx -- "-n rm -f $td/units/pithead-control.path $td/units/pithead-control.service" "$td/sudo.log"
    grep -Fqx -- "-n systemctl daemon-reload" "$td/sudo.log"
    : >"$td/sudo.log"
    # A baseline that knows its own dir asks itself, never the candidate.
    printf 'control_unit_dir() { printf %%s %q; }\n' "$td/own" >"$td/base/pithead"
    reset_control_units_for_render "$td/cand"
    grep -Fq "$td/own/pithead-control.path" "$td/sudo.log" && ! grep -Fq "$td/units/" "$td/sudo.log"
    : >"$td/sudo.log"
    # Neither knows: nothing was installed by a CLI that could say where, so nothing is removed.
    printf 'set -Eeuo pipefail\n' >"$td/base/pithead"
    printf 'set -Eeuo pipefail\n' >"$td/cand/pithead"
    reset_control_units_for_render "$td/cand"
    [ ! -s "$td/sudo.log" ]
    grep -Fq 'reset_control_units_for_render "$UPGRADE_CANDIDATE_DIR"' "$HERE/lib/live-state-support.sh"
)

echo "== every repo file the harness reads outside its own tree ships in the guest's harness tarball =="
outside="$(grep -rhoE '(\.\./){3}[A-Za-z0-9_./-]+' "$HERE/lib" "$HERE/run.sh" "$HERE/lib.sh" | sed 's|^\(\.\./\)*||' | sort -u)"
[ -n "$outside" ]
tar_line="$(grep -F 'tar --no-xattrs -czf "$stage/harness.tar.gz"' "$HERE/../os/phases/image-upgrade.sh")"
while IFS= read -r f; do
    grep -Fq -- " $f" <<<"$tar_line" || {
        echo "harness tarball misses $f" >&2
        exit 1
    }
done <<<"$outside"

echo "== a CLI without render (v1.20.0) skips the step; one with it still runs it =="
(
    IT_MODE=local IT_REMOTE_DIR="$td/renderless"
    mkdir -p "$IT_REMOTE_DIR"
    printf 'set -Eeuo pipefail\nstack_up() { :; }\n' >"$IT_REMOTE_DIR/pithead"
    ! stack_cli_has render_derived || exit 1
    printf 'render_derived() { :; }\n' >"$IT_REMOTE_DIR/pithead"
    stack_cli_has render_derived
    reset_control_units_for_render() { :; }
    baseline_up() { :; }
    wait_status_ok() { :; }
    wait_for() { :; }
    wait_miner_running() { :; }
    wait_stratum_hashes() { :; }
    RENDERED=0
    pithead() {
        [ "$1" = render ] && RENDERED=1
        return 0
    }
    start_restored_baseline && [ "$RENDERED" = 1 ] || exit 1
    printf 'set -Eeuo pipefail\n' >"$IT_REMOTE_DIR/pithead"
    RENDERED=0
    pithead() {
        [ "$1" = render ] && {
            RENDERED=1
            return 1
        }
        return 0
    }
    start_restored_baseline && [ "$RENDERED" = 0 ] && [ -z "$BASELINE_START_STEP" ] || exit 1
)

echo "== the restore reads the restored release's rows without the candidate-only schema =="
(
    rx() { printf '%s\n' "$1"; }
    snippet="$(dashboard_durable_rows 1700000000)"
    grep -Fq -- '- --require-current-schema 1700000000' <<<"$snippet"
    snippet="$(dashboard_durable_rows 1700000000 --baseline-schema)"
    ! grep -Fq -- '--require-current-schema' <<<"$snippet" || exit 1
    grep -Fq -- 'python3 -  1700000000' <<<"$snippet"
    grep -Fq 'dashboard_durable_rows "$UPGRADE_TELEMETRY_EPOCH" --baseline-schema' "$HERE/lib/live-upgrade-support.sh"
    grep -Fq 'after_telemetry="$(dashboard_durable_rows "$UPGRADE_TELEMETRY_EPOCH")"' "$HERE/lib/live-gates.sh"
)

echo "== the guest's harness stderr (skip names, failures) reaches the job log =="
grep -Fq -- '--out "$MOUNT/results" 2>&1' "$HERE/../os/image-upgrade-guest.sh"
grep -Fq '2>"$SSH_ERR"' "$HERE/../os/lib/core.sh"

echo "selftest-upgrade-layout: PASS"
