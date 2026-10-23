#!/usr/bin/env bash
set -euo pipefail
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
work_root=$(mktemp -d)
trap 'rm -rf "$work_root"' EXIT
SOURCE=$(sed -n '/^read_restart_observation() {$/,/^}/p' "$ROOT/tests/os/container-restart-leg.sh")
SOURCE+=$'\n'
SOURCE+=$(sed -nE '/^(churn_started=\$SECONDS|if ! read_restart_observation; then)$/,/^if ! restore_caddy /p' "$ROOT/tests/os/container-restart-leg.sh" | sed '$d')
run_case() (
    local scenario=$1 style=$2
    # shellcheck disable=SC2034
    local work="$work_root/$scenario-$style" ENGINE_CONTRACT_WORK=fixture waits=0
    mkdir -p "$work"
    podman() {
        [ "$3" != '{{.State.Status}}' ] || {
            printf 'running\n'
            return 0
        }
        local n=0 start count template=$3
        [ ! -f "$work/snapshots" ] || n=$(<"$work/snapshots")
        n=$((n + 1))
        printf '%s\n' "$n" >"$work/snapshots"
        count=$n
        if [ "$style" = podman ]; then start="2026-10-20 00:00:0$n.123456789 +0000 UTC"; else start="2026-10-20T00:00:0${n}Z"; fi
        case "$scenario" in
        stationary-count) count=1 ;;
        stationary-start) start='2026-10-20 00:00:01.123456789 +0000 UTC' ;;
        malformed-count) count=invalid ;;
        missing-start) start='' ;;
        multiple-rows)
            printf '%s\t%s\n%s\t%s\n' "$start" "$count" "$start" "$count"
            return 0
            ;;
        failed-read) return 7 ;;
        failed-with-output)
            printf '%s\t%s\n' "$start" "$count"
            return 7
            ;;
        esac
        template=${template//'{{.State.StartedAt}}'/"$start"}
        template=${template//'{{.RestartCount}}'/"$count"}
        printf '%s\n' "$template"
    }
    timeout() {
        case "$*" in
        '30 ./.pithead-baseline status') return 0 ;;
        '30 ./pithead status')
            printf 'caddy restarting\n'
            return 1
            ;;
        '30 ./pithead doctor')
            printf 'caddy is restarting or restarted during the health check\n'
            return 1
            ;;
        '30 bash fixture/engine-contract-predicate.sh') return 1 ;;
        *) return 97 ;;
        esac
    }
    sleep() {
        waits=$((waits + 1))
        SECONDS=$((SECONDS + $1))
    }
    eval "$SOURCE"
    # shellcheck disable=SC2154
    [ "$waits" -gt 0 ] && [ "$((SECONDS - churn_started))" -ge 30 ]
)
for style in podman docker; do
    if ! run_case advancing "$style" >"$work_root/pass-$style.log" 2>&1; then
        cat "$work_root/pass-$style.log" >&2
        echo "FAIL: $style advancing observation rejected" >&2
        exit 1
    fi
    for scenario in stationary-count stationary-start malformed-count missing-start multiple-rows failed-read failed-with-output; do
        if run_case "$scenario" "$style" >"$work_root/$scenario-$style.log" 2>&1; then
            echo "FAIL: $style $scenario observation passed" >&2
            exit 1
        fi
    done
done
printf 'engine contract independent observation selftest: PASS\n'
