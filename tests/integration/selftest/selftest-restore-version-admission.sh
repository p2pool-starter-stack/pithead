#!/usr/bin/env bash
# shellcheck disable=SC2034
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$HERE/lib.sh"
sandbox=$(mktemp -d) || exit 1
trap 'rm -rf "$sandbox"' EXIT
main_src=$(sed -n '/^main() {$/,/^}$/p' "$HERE/e2e.sh")
for fixture in equal older unstamped prerelease newer canonical-newer unreadable invalid-version invalid-config transport; do
    printf '2.0.0\n' >"$sandbox/VERSION"
    printf '{"config_version":"2.0.0"}\n' >"$sandbox/config.json"
    mkdir -p "$sandbox/canonical"
    cp "$sandbox/config.json" "$sandbox/canonical/config.json"
    case "$fixture" in
    canonical-newer) printf '{"config_version":"2.0.1"}\n' >"$sandbox/canonical/config.json" ;;
    older) printf '2.0.1\n' >"$sandbox/VERSION" ;;
    unstamped) printf '{}\n' >"$sandbox/config.json" ;;
    prerelease) printf '2.0.0-pre.1+build\n' >"$sandbox/VERSION" ;;
    newer) printf '{"config_version":"2.0.1"}\n' >"$sandbox/config.json" ;;
    unreadable) rm "$sandbox/config.json" ;;
    invalid-version) printf 'invalid\n' >"$sandbox/VERSION" ;;
    invalid-config) printf '{"secret":"never-print-this",\n' >"$sandbox/config.json" ;;
    esac
    : >"$sandbox/events"
    out=$(
        (
            BRANCH=fixture BENCH_HOST=fixture MODE=targeted KEEP=0 RESTORED=0 E2E_DIR="$sandbox" CANONICAL_DIR="$sandbox/canonical"
            log() { :; }
            ok() { :; }
            die() {
                printf '%s\n' "$*"
                exit 1
            }
            preflight() { :; }
            provision() { :; }
            backup_stack() { echo backup >>"$sandbox/events"; }
            wallet_fixture_capture() { echo wallet >>"$sandbox/events"; }
            borrow_miner() { echo borrow >>"$sandbox/events"; }
            deploy_branch() { echo deploy >>"$sandbox/events"; }
            run_harness() { echo harness >>"$sandbox/events"; }
            on_bench() { [ "$fixture" != transport ] && bash -c "$1"; }
            trap '[ "$RESTORED" = 1 ] || echo restore >>"$sandbox/events"' EXIT
            eval "$main_src"
            main
        ) 2>&1
    )
    rc=$?
    case "$fixture" in
    equal | older | unstamped | prerelease)
        assert_rc "$fixture admitted" "$rc" 0
        assert_contains "$fixture reaches deployment" "$(cat "$sandbox/events")" deploy
        ;;
    *)
        assert_rc "$fixture refused" "$rc" 1
        assert_eq "$fixture causes no backup, wallet, borrow, deployment or restore" "$(cat "$sandbox/events")" ""
        if [ "$fixture" = newer ] || [ "$fixture" = canonical-newer ]; then
            assert_contains "refusal identifies required candidate version" "$out" "Use a candidate 2.0.1 or later"
        fi
        ;;
    esac
    case "$out" in
    *never-print-this*) it_fail "$fixture hides configuration contents" leaked ;;
    *) it_pass "$fixture hides configuration contents" ;;
    esac
done
INTEGRATION_RUN_SUITE=1
source "$HERE/lib/run-safety.sh"
for fixture in equal newer transport; do
    mkdir -p "$sandbox/out"
    printf '2.0.0\n' >"$sandbox/VERSION"
    printf '{"config_version":"2.0.0"}\n' >"$sandbox/config.json"
    [ "$fixture" != newer ] || printf '{"config_version":"2.0.1"}\n' >"$sandbox/config.json"
    : >"$sandbox/.env"
    : >"$sandbox/events"
    out=$(
        (
            SAFETY_BACKUP=1 RUN_IMAGE_UPGRADE=0 OUT_DIR="$sandbox/out" SAFETY_ARCHIVE=""
            IT_MODE=ssh IT_REMOTE_DIR="$sandbox" IT_SSH_DEST=fixture IT_SSH_OPTS=()
            ssh() {
                [ "$fixture" != transport ] || return 1
                if [ "$1" = -n ]; then
                    shift
                    bash -c "$2" </dev/null
                else
                    bash -c "$2"
                fi
            }
            pithead() {
                echo backup >>"$sandbox/events"
                tar -czf "$sandbox/backup.tar.gz" -C "$sandbox" config.json .env || return 1
                printf 'Backup written to: %s\n' "$sandbox/backup.tar.gz"
            }
            wait_status_ok() { echo healthy >>"$sandbox/events"; }
            safety_cleanup() { echo cleanup >>"$sandbox/events"; }
            safety_backup
        ) 2>&1
    )
    rc=$?
    if [ "$fixture" = equal ]; then
        assert_rc "standalone valid safety archive admitted" "$rc" 0
        assert_contains "standalone validates recovery health" "$(cat "$sandbox/events")" healthy
    else
        assert_rc "standalone $fixture refused" "$rc" 1
        assert_eq "standalone $fixture starts no backup or cleanup" "$(cat "$sandbox/events")" ""
    fi
done
printf 'restore admission: %s passed, %s failed\n' "$IT_PASS" "$IT_FAIL"
[ "$IT_FAIL" -eq 0 ]
