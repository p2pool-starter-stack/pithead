#!/usr/bin/env bash
set -uo pipefail

DIY_ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
: "${DIY_STATE_DIR:=/var/lib/pithead-diy-lifecycle}"
: "${DIY_REBOOT_MARKER:=/var/lib/cloud/diy-reboot-resume}"
: "${DIY_REPO_URL:=https://github.com/p2pool-starter-stack/pithead}"
: "${DIY_BOOT_ID_FILE:=/proc/sys/kernel/random/boot_id}"
DIY_LOG_DIR=$DIY_STATE_DIR/logs
DIY_WORK=$DIY_STATE_DIR/work
DIY_ANSWERS=$DIY_STATE_DIR/answers.json
DIY_BENCH_ISSUE=p2pool-starter-stack/bench-ci#2456
DIY_DIR=$DIY_ROOT
# shellcheck source=tests/diy/lib.sh
source "$DIY_ROOT/tests/diy/lib.sh"
# shellcheck source=tests/diy/upgrade.sh
source "$DIY_ROOT/tests/diy/upgrade.sh"

pt() { (cd "$DIY_DIR" && ./pithead "$@"); }
services_running() { (cd "$DIY_DIR" && docker compose ps --status running --services); }
monero_local() { [ "$(jq -r '.monero.mode // "local"' "$DIY_DIR/config.json")" = local ]; }

gate_holds() {
    local deadline=$((SECONDS + 900)) running
    while :; do
        running=$(services_running) || running=""
        grep -x monerod <<<"$running" >/dev/null && break
        [ "$SECONDS" -lt "$deadline" ] || {
            echo "monerod never started"
            return 1
        }
        sleep 5
    done
    for _ in 1 2 3 4; do
        running=$(services_running) || {
            echo "could not list the running services"
            return 1
        }
        if grep -Ex 'p2pool|xmrig-proxy' <<<"$running" >/dev/null; then
            echo "p2pool or xmrig-proxy is running before the chains sync"
            printf '%s\n' "$running"
            return 1
        fi
        sleep 10
    done
}

step_gate() {
    if ! monero_local; then
        diy_missing "$1" "the config uses a remote Monero node, so no first-boot sync gate applies"
        return 0
    fi
    diy_step "$1" "monerod running, p2pool and xmrig-proxy held" gate_holds
}

clean_start_checks() {
    local findings
    [ "$(id -u)" = 0 ] || {
        echo "not running as root"
        return 1
    }
    (
        . /etc/os-release
        [ "$ID" = ubuntu ] && [ "$VERSION_ID" = 24.04 ]
    ) || {
        echo "not Ubuntu 24.04"
        return 1
    }
    [ -s "$DIY_DIR/config.json" ] || {
        echo "no staged config.json"
        return 1
    }
    [ ! -e "$DIY_DIR/.env" ] || {
        echo ".env already present"
        return 1
    }
    findings=$(diy_residue_scan)
    ! command -v docker >/dev/null 2>&1 || findings+=$(docker images --format 'image: {{.Repository}}:{{.Tag}}' 2>/dev/null)
    [ -z "$findings" ] || {
        echo "$findings"
        return 1
    }
}

prerequisites_check() {
    local tool
    DEBIAN_FRONTEND=noninteractive bash -c 'sudo apt update && sudo apt install -y jq docker.io docker-compose-v2 openssl python3' || return 1
    for tool in jq openssl python3 docker; do
        command -v "$tool" >/dev/null || {
            echo "$tool missing after the documented install"
            return 1
        }
    done
    docker compose version
}

release_download_check() {
    local dir=$DIY_WORK/latest
    rm -rf "$dir"
    mkdir -p "$dir"
    curl -fsSL "$DIY_REPO_URL/releases/latest/download/pithead.tar.gz" | tar xz -C "$dir" || return 1
    (cd "$dir/pithead" && ./pithead version)
}

build_candidate() {
    (cd "$DIY_ROOT" && bash scripts/build-pithead.sh && ./pithead version | grep -F "$(cat VERSION)")
}

wizard_defaults() {
    local wallet
    wallet=$(jq -er '.monero.wallet_address' "$DIY_ANSWERS") || return 1
    rm -f "$DIY_DIR/config.json"
    (cd "$DIY_DIR" && python3 -I "$DIY_ROOT/tests/diy/pty-answer.py" "$wallet" 1800 ./pithead setup --skip-optimize) || return 1
    jq -e --arg wallet "$wallet" '.monero.wallet_address == $wallet and .xvb.enabled == false and
        .monero.clearnet_initial_sync == false and .tari.mode == "off" and .p2pool.pool == "mini" and
        .dashboard.secure == true and (.dashboard.auth.password | length) == 32' "$DIY_DIR/config.json" >/dev/null
}

restore_answers() {
    install -m 600 "$DIY_ANSWERS" "$DIY_DIR/config.json"
}

setup_prepared() {
    local out
    restore_answers || return 1
    out=$(cd "$DIY_DIR" && printf '\nn\n' | timeout 1800 ./pithead setup --skip-optimize 2>&1) || {
        printf '%s\n' "$out"
        return 1
    }
    printf '%s\n' "$out"
    grep -F "Deployment preparation complete" <<<"$out" >/dev/null &&
        grep -x 'DEPLOYMENT_COMPLETED=true' "$DIY_DIR/.env" >/dev/null &&
        [ -n "$(systemctl list-unit-files --plain --no-legend 'pithead-*')" ]
}

up_first() {
    (cd "$DIY_DIR" && rm -f .pithead-first-run-done && timeout 2400 ./pithead up)
}

status_held() {
    local out deadline=$((SECONDS + 300))
    while [ "$SECONDS" -lt "$deadline" ]; do
        out=$(pt status 2>&1)
        grep -F "miner is held until it completes" <<<"$out" >/dev/null && return 0
        sleep 10
    done
    printf '%s\n' "$out"
    return 1
}

apply_change() {
    local before_env before_fp other tmp
    other=$(diy_other_pool "$DIY_DIR/config.json")
    before_env=$(sha256sum "$DIY_DIR/.env")
    before_fp=$(diy_secret_fingerprint "$DIY_DIR/.env")
    tmp=$(mktemp)
    jq --arg pool "$other" '.p2pool.pool = $pool' "$DIY_DIR/config.json" >"$tmp" && install -m 600 "$tmp" "$DIY_DIR/config.json"
    rm -f "$tmp"
    (cd "$DIY_DIR" && timeout 1800 ./pithead apply -y) || return 1
    [ "$(sha256sum "$DIY_DIR/.env")" != "$before_env" ] || {
        echo ".env unchanged after the pool change"
        return 1
    }
    [ "$(diy_secret_fingerprint "$DIY_DIR/.env")" = "$before_fp" ] || {
        echo "secrets changed across apply"
        return 1
    }
}

doctor_check() {
    local out rc=0
    out=$(cd "$DIY_DIR" && ./pithead doctor --json 2>/dev/null) || rc=$?
    jq -e --argjson rc "$rc" '.exit == $rc and (.checks | length) > 0' <<<"$out" >/dev/null || {
        echo "doctor --json did not report a usable verdict"
        return 1
    }
    jq -r '.summary | "doctor: ok=\(.ok) warn=\(.warn) fail=\(.fail)"' <<<"$out"
    jq -r '.checks[] | select(.status == "fail") | .message' <<<"$out" | grep -viE 'sync' && return 1
    return 0
}

rotate_check() {
    local before
    before=$(diy_secret_fingerprint "$DIY_DIR/.env")
    (cd "$DIY_DIR" && timeout 1800 ./pithead rotate-secrets -y) || return 1
    [ "$(diy_secret_fingerprint "$DIY_DIR/.env")" != "$before" ] || {
        echo "secrets unchanged after rotate-secrets"
        return 1
    }
}

backup_check() {
    (cd "$DIY_DIR" && timeout 1800 ./pithead backup -y --no-encrypt) || return 1
    ARCHIVE=$(ls -t "$DIY_DIR"/backups/pithead-backup-*.tar.gz 2>/dev/null | head -n 1)
    [ -s "$ARCHIVE" ]
}

restore_check() {
    local want_config want_fp tmp other
    want_config=$(jq -S . "$DIY_DIR/config.json")
    want_fp=$(diy_secret_fingerprint "$DIY_DIR/.env")
    (cd "$DIY_DIR" && ./pithead down) || return 1
    other=$(diy_other_pool "$DIY_DIR/config.json")
    tmp=$(mktemp)
    jq --arg pool "$other" '.p2pool.pool = $pool' "$DIY_DIR/config.json" >"$tmp" && install -m 600 "$tmp" "$DIY_DIR/config.json"
    rm -f "$tmp"
    (cd "$DIY_DIR" && timeout 1800 ./pithead restore -y "$ARCHIVE") || return 1
    [ "$(jq -S . "$DIY_DIR/config.json")" = "$want_config" ] || {
        echo "restore did not bring back the backed-up config"
        return 1
    }
    [ "$(diy_secret_fingerprint "$DIY_DIR/.env")" = "$want_fp" ] || {
        echo "restore did not bring back the backed-up secrets"
        return 1
    }
    (cd "$DIY_DIR" && timeout 2400 ./pithead up)
}

kept_paths() {
    local key
    printf '%s\n' "$DIY_DIR/config.json" "$DIY_DIR/backups"
    for key in MONERO TARI P2POOL DASHBOARD TOR; do
        sed -n "s/^${key}_DATA_DIR=//p" "$DIY_DIR/.env" | tr -d "'\""
    done
}

stop_and_snapshot() {
    (cd "$DIY_DIR" && ./pithead down) || return 1
    kept_paths >"$DIY_STATE_DIR/kept-paths"
    local kept_path
    while read -r kept_path; do
        [ -e "$kept_path" ] || [ "$kept_path" = "$DIY_DIR/backups" ] || {
            echo "kept path missing before uninstall: $kept_path"
            return 1
        }
    done <"$DIY_STATE_DIR/kept-paths"
    (cd "$DIY_DIR" && docker compose config --images | sort -u) >"$DIY_STATE_DIR/images.txt" || return 1
    mapfile -t KEPT <"$DIY_STATE_DIR/kept-paths"
    diy_tree_digest "${KEPT[@]}" >"$DIY_STATE_DIR/kept.digest"
}

kept_unchanged() {
    local now
    mapfile -t KEPT <"$DIY_STATE_DIR/kept-paths"
    now=$(diy_tree_digest "${KEPT[@]}")
    [ "$now" = "$(cat "$DIY_STATE_DIR/kept.digest")" ]
}

uninstall_check() {
    (cd "$DIY_DIR" && timeout 1800 ./pithead uninstall -y) || return 1
    [ ! -e "$DIY_DIR/.env" ]
}

uninstall_phase() {
    local p=$1
    diy_step "$p-stop" "stack stopped and kept data snapshotted" stop_and_snapshot || return 1
    diy_step "$p-uninstall" "uninstall -y exits 0 and removes .env" uninstall_check || return 1
    diy_assert_no_residue "$p"
    if kept_unchanged; then
        diy_pass "$p-kept-data" "config.json, every data dir and backups/ byte-identical"
    else
        diy_fail "$p-kept-data" "kept data changed across uninstall"
    fi
}

reboot_handoff() {
    if [ ! -e "$DIY_REBOOT_MARKER" ]; then
        diy_missing reboot-residue "the lane does not reboot the guest after exit 75 yet ($DIY_BENCH_ISSUE)"
        return 0
    fi
    cat "$DIY_BOOT_ID_FILE" >"$DIY_STATE_DIR/boot-id"
    return 75
}

after_reboot() {
    if [ ! -s "$DIY_STATE_DIR/kept.digest" ]; then
        diy_fail after-reboot-state "no state was left by the first session"
        return 0
    fi
    diy_step after-reboot-booted "the guest booted since uninstall" \
        bash -c '[ "$(cat "$1")" != "$(cat "$2")" ]' _ "$DIY_BOOT_ID_FILE" "$DIY_STATE_DIR/boot-id"
    diy_assert_no_residue reboot
    if kept_unchanged; then
        diy_pass reboot-kept-data "config.json, every data dir and backups/ still byte-identical"
    else
        diy_fail reboot-kept-data "kept data changed across the reboot"
    fi
}

phase_candidate() {
    diy_step clean-start "root on Ubuntu 24.04 with only config.json staged and no Pithead state" clean_start_checks
    DOCKER_AT_START=0
    ! command -v docker >/dev/null 2>&1 || DOCKER_AT_START=1
    diy_step prerequisites "documented apt command installs jq, Docker, Compose, openssl and python3" prerequisites_check
    if [ "$DOCKER_AT_START" = 1 ]; then
        diy_missing install-docker "Docker was already installed when the guest started ($DIY_BENCH_ISSUE)"
    else
        diy_step install-docker "Docker installed by the documented command and answering" docker info
    fi
    diy_step release-download "documented latest-release download unpacks and runs" release_download_check
    diy_step build-from-source "scripts/build-pithead.sh yields ./pithead at the candidate VERSION" build_candidate || return 1
    diy_step setup-defaults "the wizard on a terminal writes the documented defaults" wizard_defaults || return 1
    diy_step wizard-uninstall "uninstall -y after the wizard run" uninstall_check
    diy_step setup-prepared "setup from the prepared config.json completes" setup_prepared || return 1
    diy_step up "up exits 0" up_first || return 1
    diy_step up-first-note "first start names the held miner" \
        grep -F "The miner is held until the initial sync finishes for" "$DIY_LOG_DIR/up.log"
    step_gate sync-gate
    diy_step status-held "status reports the miner held" status_held
    diy_step apply "apply of a pool change re-renders and keeps secrets" apply_change
    step_gate sync-gate-after-apply
    diy_step doctor "doctor --json gives a verdict with no non-sync failures" doctor_check
    diy_step rotate-secrets "rotate-secrets -y changes the secrets" rotate_check
    step_gate sync-gate-after-rotate
    diy_step backup "backup -y --no-encrypt writes an archive" backup_check || return 1
    diy_step restore "restore -y brings back the backed-up config and secrets" restore_check || return 1
    step_gate sync-gate-after-restore
    uninstall_phase uninstall-candidate
}

phase_previous() {
    diy_step previous-release "highest release tag below VERSION downloaded and signature-verified" previous_release_check || return 1
    printf 'LIFECYCLE-INFO previous-release=%s\n' "$(cat "$DIY_STATE_DIR/previous-tag")"
    diy_step previous-install "previous release unpacked with the prepared config" install_previous || return 1
    diy_step previous-setup "previous release setup completes" setup_prepared || return 1
    diy_step previous-up "previous release up exits 0" up_first || return 1
    step_gate previous-sync-gate
    diy_step upgrade "upgrade from the previous release to the candidate" upgrade_check || return 1
    step_gate upgrade-sync-gate
    uninstall_phase uninstall-upgraded
}

main() {
    if [ "${1:-}" = --after-reboot ]; then
        after_reboot
        diy_summary
        exit $?
    fi
    [ "$#" -eq 0 ] || {
        echo "usage: tests/diy/lifecycle.sh [--after-reboot]" >&2
        exit 2
    }
    mkdir -p "$DIY_LOG_DIR" "$DIY_WORK"
    chmod 700 "$DIY_STATE_DIR"
    [ -s "$DIY_ROOT/config.json" ] && install -m 600 "$DIY_ROOT/config.json" "$DIY_ANSWERS"
    phase_candidate
    DIY_DIR=$DIY_ROOT
    [ "$DIY_FAIL" -ne 0 ] || phase_previous
    if [ "$DIY_FAIL" -eq 0 ]; then
        reboot_handoff
        local rc=$?
        diy_summary
        local summary_rc=$?
        [ "$rc" -ne 75 ] || exit 75
        exit "$summary_rc"
    fi
    diy_summary
    exit 1
}

[ "${BASH_SOURCE[0]}" != "$0" ] || main "$@"
