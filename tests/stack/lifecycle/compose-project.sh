#!/usr/bin/env bash
set -euo pipefail
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)
sandbox=$(mktemp -d)
trap 'rm -rf "$sandbox"' EXIT
cd "$sandbox"
# shellcheck source=lib/pithead/19-small-utilities.sh
source "$ROOT/lib/pithead/19-small-utilities.sh"
# shellcheck source=lib/pithead/01-lifecycle.sh
source "$ROOT/lib/pithead/01-lifecycle.sh"
# shellcheck source=lib/pithead/01a-configless-recovery.sh
source "$ROOT/lib/pithead/01a-configless-recovery.sh"
# shellcheck source=lib/pithead/02b-lan-guard.sh
source "$ROOT/lib/pithead/02b-lan-guard.sh"
# shellcheck source=lib/pithead/02b-lan-guard-units.sh
source "$ROOT/lib/pithead/02b-lan-guard-units.sh"
# shellcheck source=lib/pithead/02b1-lan-guard-compose.sh
source "$ROOT/lib/pithead/02b1-lan-guard-compose.sh"
# shellcheck source=lib/pithead/02c-lan-guard-check.sh
source "$ROOT/lib/pithead/02c-lan-guard-check.sh"
warn() { printf '%s\n' "$*" >&2; }
log() { :; }
check() {
    if [ "$2" != "$3" ]; then
        printf 'FAIL: %s: expected [%s], got [%s]\n' "$1" "$3" "$2" >&2
        exit 1
    fi
    printf 'PASS: %s\n' "$1"
}
unset COMPOSE_PROJECT_NAME
export ENV_FILE=.env
check 'default project' "$(compose_project_name)" pithead
printf 'COMPOSE_PROJECT_NAME=pithead-gate\n' >.env
check 'env project' "$(compose_project_name)" pithead-gate
printf 'COMPOSE_PROJECT_NAME="pithead-gate"\n' >.env
check 'double-quoted env project' "$(compose_project_name)" pithead-gate
printf "COMPOSE_PROJECT_NAME='pithead-gate'\n" >.env
check 'single-quoted env project' "$(compose_project_name)" pithead-gate
check 'export overrides env' "$(COMPOSE_PROJECT_NAME=other-project compose_project_name)" other-project
check 'empty export overrides env with default' "$(COMPOSE_PROJECT_NAME='' compose_project_name)" pithead
if COMPOSE_PROJECT_NAME='invalid/name' compose_project_name >/dev/null 2>&1; then exit 1; fi
printf 'PASS: invalid project refused\n'
for declaration in \
    $'COMPOSE_PROJECT_NAME=pithead\nCOMPOSE_PROJECT_NAME=pithead-gate' \
    ' COMPOSE_PROJECT_NAME=pithead-gate' \
    'export COMPOSE_PROJECT_NAME=pithead-gate' \
    'COMPOSE_PROJECT_NAME="pithead-\gate"' \
    'COMPOSE_PROJECT_NAME="pithead-gate' \
    'COMPOSE_PROJECT_NAME=${OTHER_PROJECT}' \
    'COMPOSE_PROJECT_NAME=pithead-gate # inline'; do
    printf '%s\n' "$declaration" >.env
    if compose_project_name >/dev/null 2>&1; then exit 1; fi
done
printf 'PASS: ambiguous and non-literal env project assignments refused\n'
printf 'COMPOSE_PROJECT_NAME=pithead-gate\n' >.env
DOCKER_LOG="$sandbox/docker.log"
docker() {
    printf '%s\n' "$*" >>"$DOCKER_LOG"
    case "$*" in
    'ps -a --filter label=com.docker.compose.project=pithead-gate --format {{.Names}}') printf '123456789abc_tari\n' ;;
    'compose config --format json') printf '{"name":"pithead-gate","services":{"monerod":{"container_name":"monerod"}}}\n' ;;
    esac
}
restore_recreate_names
check 'recreate targets configured project' "$(tail -1 "$DOCKER_LOG")" 'rename 123456789abc_tari tari'
: >"$DOCKER_LOG"
configless_project_ids
check 'custom configless census excludes default and legacy projects' "$(cat "$DOCKER_LOG")" 'ps --all --quiet --filter label=com.docker.compose.project=pithead-gate'
mkdir pithead
cd pithead
: >"$DOCKER_LOG"
migrate_compose_project
check 'custom project never migrates containers from the default project' "$(cat "$DOCKER_LOG")" 'compose config --format json'
cd "$sandbox"
LAN_GUARD_BINDS='TARI_GRPC_BIND:18142'
LAN_GUARD_STOPPED_SERVICES=()
lan_guard_published() { printf '%s\n' "$LAN_GUARD_BINDS"; }
: >"$DOCKER_LOG"
lan_guard_stop_published
check 'LAN stop selects custom project' "$(cat "$DOCKER_LOG")" 'ps -q --filter label=com.docker.compose.project=pithead-gate --filter label=com.docker.compose.service=tari'
printf 'TARI_GRPC_BIND=0.0.0.0\nCOMPOSE_PROJECT_NAME=pithead-gate\n' >.env
lan_guard_watched_ports() { printf '18142\n'; }
lan_guard_enforced() { return 1; }
lan_guard_marker_current() { return 1; }
lan_guard_unmark() { return 0; }
apply_lan_guard() { return 0; }
docker() {
    printf '%s\n' "$*" >>"$DOCKER_LOG"
    case "$1" in ps) return 1 ;; esac
}
: >"$DOCKER_LOG"
if lan_guard_check_now >/dev/null 2>&1; then exit 1; fi
if grep -q '^stop ' "$DOCKER_LOG"; then exit 1; fi
check 'failed custom census stops no node' "${#LAN_GUARD_STOPPED_SERVICES[@]}" 0
printf 'PASS: custom project cannot stop default node names when its census fails\n'
printf 'Compose project ownership checks passed\n'
