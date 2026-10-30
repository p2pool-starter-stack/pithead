#!/usr/bin/env bash
# shellcheck disable=SC2329
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
td=$(mktemp -d)
trap 'rm -rf "$td"' EXIT
export PATH="$td/bin:$PATH" RESTART_STATE="$td/state"
mkdir -p "$td/bin"

cat >"$td/bin/fake-engine" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
case "$1" in
compose)
    case "$*" in
    'compose config --services') printf '%s\n' "${SERVICE_NAME:-caddy}" ;;
    'compose ps') ;;
    *) printf 'fixture-id\n' ;;
    esac
    ;;
inspect)
    case "$3" in
    *RestartCount*) case "$3" in *$'\t'*) ;; *) exit 3 ;; esac ;;
    *) printf '%s none\n' "${SERVICE_STATE:-running}"; exit 0 ;;
    esac
    n=0
    [ ! -f "$RESTART_STATE" ] || n=$(<"$RESTART_STATE")
    n=$((n + 1))
    printf '%s\n' "$n" >"$RESTART_STATE"
    case "${RESTART_SCENARIO:?}" in
    advancing) printf '%064d\t/caddy\trunning\t%s\t2026-10-20T00:00:0%sZ\n' 1 "$n" "$n" ;;
    stable) printf '%064d\t/caddy\trunning\t7\t2026-10-20T00:00:01Z\n' 1 ;;
    backoff) printf '%064d\t/caddy\trestarting\t7\t2026-10-20T00:00:01Z\n' 1 ;;
    backoff_after)
        [ "$n" -eq 1 ] && state=running || state=restarting
        printf '%064d\t/caddy\t%s\t7\t2026-10-20T00:00:01Z\n' 1 "$state"
        ;;
    backoff_replacement)
        [ "$n" -eq 1 ] && state=running || state=restarting
        printf '%064d\t/caddy\t%s\t7\t2026-10-20T00:00:01Z\n' "$n" "$state"
        ;;
    started) printf '%064d\t/caddy\trunning\t0\t2026-10-20T00:00:0%sZ\n' 1 "$n" ;;
    replacement) printf '%064d\t/caddy\trunning\t%s\t2026-10-20T00:00:0%sZ\n' "$n" "$n" "$n" ;;
    firststart)
        if [ "$n" -eq 1 ]; then
            printf '%064d\t/caddy\tcreated\t0\t0001-01-01T00:00:00Z\n' 1
        else
            printf '%064d\t/caddy\trunning\t0\t2026-10-20T00:00:02Z\n' 1
        fi
        ;;
    malformed) printf 'not-a-row\n' ;;
    failed) exit 1 ;;
    esac
    ;;
*) exit 2 ;;
esac
SH
chmod +x "$td/bin/fake-engine"
ln -s fake-engine "$td/bin/docker"
ln -s fake-engine "$td/bin/podman"
printf '#!/usr/bin/env bash\nexit 0\n' >"$td/bin/sleep"
chmod +x "$td/bin/sleep"

ENGINE=docker
container_engine() { printf '%s' "$ENGINE"; }
source "$ROOT/lib/pithead/04a-container-restarts.sh"

check_scenario() {
    local scenario="$1" expected="$2" actual
    rm -f "$RESTART_STATE"
    export RESTART_SCENARIO="$scenario"
    actual=$(container_restarting_names)
    [ "$actual" = "$expected" ] || {
        printf 'FAIL: %s: expected <%s>, got <%s>\n' "$scenario" "$expected" "$actual" >&2
        exit 1
    }
}

for ENGINE in docker podman; do
    check_scenario advancing caddy
    check_scenario started caddy
    check_scenario stable ''
    check_scenario backoff caddy
    check_scenario backoff_after caddy
    check_scenario backoff_replacement caddy
    check_scenario replacement ''
    check_scenario firststart ''
done
if RESTART_SCENARIO=malformed container_restarting_names >/dev/null 2>&1; then
    printf 'FAIL: malformed engine output passed\n' >&2
    exit 1
fi
if RESTART_SCENARIO=failed container_restarting_names >/dev/null 2>&1; then
    printf 'FAIL: failed engine read passed\n' >&2
    exit 1
fi

C_RED='' C_GREEN='' C_YELLOW='' C_RESET=''
REVENUE_CHAIN_CONTAINERS='monerod tari wallet-rpc tari-wallet'
env_get() { [ "$1" = COMPOSE_PROFILES ] && printf 'local_node'; }
MIGRATION_HOLD=0
os_migration_hold_active() { [ "$MIGRATION_HOLD" -eq 1 ]; }
monero_chain_status_line() { :; }
tari_chain_status_line() { :; }
dashboard_syncing() { return 1; }
dashboard_sync_progress() { return 1; }
print_clearnet_banner() { :; }
dashboard_onion_status() { return 1; }
announce_stratum_auth() { :; }
announce_stratum_tls() { :; }
log() { printf '%s\n' "$*"; }
warn() { printf '%s\n' "$*"; }
source "$ROOT/lib/pithead/04-status.sh"

ENGINE=docker
rm -f "$RESTART_STATE"
export RESTART_SCENARIO=advancing
container_restarting_names() { :; }
stack_status >"$td/baseline-status.out" 2>&1 || {
    printf 'FAIL: pre-fix status negative control unexpectedly caught caddy\n' >&2
    exit 1
}
source "$ROOT/lib/pithead/04a-container-restarts.sh"
export RESTART_SCENARIO=advancing
rm -f "$RESTART_STATE"
if stack_status >"$td/status.out" 2>&1; then
    printf 'FAIL: status passed an advancing caddy restart\n' >&2
    exit 1
fi
grep -Fq 'caddy         restarting' "$td/status.out" || {
    printf 'FAIL: status did not name restarting caddy\n' >&2
    exit 1
}

export RESTART_SCENARIO=backoff
rm -f "$RESTART_STATE"
if stack_status >"$td/backoff-status.out" 2>&1; then
    printf 'FAIL: status passed caddy in restart backoff\n' >&2
    exit 1
fi
grep -Fq 'caddy         restarting' "$td/backoff-status.out" || {
    printf 'FAIL: status did not name caddy in restart backoff\n' >&2
    exit 1
}

export RESTART_SCENARIO=stable
rm -f "$RESTART_STATE"
stack_status >"$td/stable-status.out" 2>&1 || {
    printf 'FAIL: stable historical restart count failed status\n' >&2
    exit 1
}
export RESTART_SCENARIO=malformed
rm -f "$RESTART_STATE"
if stack_status >"$td/malformed-status.out" 2>&1; then
    printf 'FAIL: malformed restart observation passed status\n' >&2
    exit 1
fi

export RESTART_SCENARIO=stable SERVICE_NAME=p2pool SERVICE_STATE=exited
rm -f "$RESTART_STATE"
stack_status >"$td/sync-hold.out" 2>&1 || {
    printf 'FAIL: intentional stopped miner no longer passes status\n' >&2
    exit 1
}
export SERVICE_NAME=monerod MIGRATION_HOLD=1
rm -f "$RESTART_STATE"
stack_status >"$td/migration-hold.out" 2>&1 || {
    printf 'FAIL: migration-held chain service no longer passes status\n' >&2
    exit 1
}
grep -Fq 'intentionally held until this slot commits' "$td/migration-hold.out" || {
    printf 'FAIL: migration hold case did not exercise the held-service branch\n' >&2
    exit 1
}
export SERVICE_NAME=caddy SERVICE_STATE=running MIGRATION_HOLD=0 RESTART_SCENARIO=advancing

DR_ROWS=
dr_fail() { DR_ROWS="${DR_ROWS}${DR_ROWS:+$'\n'}fail:$2"; }
dr_ok() { DR_ROWS="${DR_ROWS}${DR_ROWS:+$'\n'}ok:$2"; }
source "$ROOT/lib/pithead/21-doctor-stack-checks.sh"
export RESTART_SCENARIO=malformed
rm -f "$RESTART_STATE"
check_container_restarts
grep -Fq 'fail:Container restart observation failed' <<<"$DR_ROWS" || {
    printf 'FAIL: malformed restart observation passed doctor\n' >&2
    exit 1
}
for RESTART_SCENARIO in advancing backoff; do
    export RESTART_SCENARIO
    DR_ROWS=
    rm -f "$RESTART_STATE"
    check_container_restarts
    grep -Fq 'fail:caddy is restarting or restarted during the health check' <<<"$DR_ROWS" || {
        printf 'FAIL: doctor did not name caddy in %s\n' "$RESTART_SCENARIO" >&2
        exit 1
    }
done
printf 'container restart self-test: PASS\n'
