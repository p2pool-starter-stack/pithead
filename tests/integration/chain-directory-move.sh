#!/usr/bin/env bash
set -euo pipefail
original=$(pwd -P)
work=$(mktemp -d "${TMPDIR:?}/pithead-chain-move.XXXXXX")
moved="$work/pithead-v0.0.0"
mkdir "$moved"
restore() {
    local rc=$?
    trap - EXIT
    if ! (cd "$original" && PITHEAD_STEAL_CONTROL_UNITS=1 ./pithead render && PITHEAD_PULL=never ./pithead up); then
        printf '%s\n' 'chain directory move: restoration failed' >&2
        exit 1
    fi
    find "$work" -depth -delete
    exit "$rc"
}
trap restore EXIT
for file in pithead docker-compose.yml config.json .env config.reference.json config.core-keys.json VERSION; do
    cp -p "$original/$file" "$moved/$file"
done
cp -a "$original/build" "$moved/build"
if [ -f "$original/dashboard/Dockerfile" ]; then
    cp -a "$original/dashboard" "$moved/dashboard"
fi
mapfile -t data_dirs < <(
    source "$original/pithead"
    for key in MONERO_DATA_DIR TARI_DATA_DIR P2POOL_DATA_DIR TOR_DATA_DIR DASHBOARD_DATA_DIR; do
        env_get "$key"
        printf '\n'
    done
)
[ "${#data_dirs[@]}" = 5 ]
for data_dir in "${data_dirs[@]}"; do [ -n "$data_dir" ]; done
jq --arg m "${data_dirs[0]}" --arg t "${data_dirs[1]}" --arg p "${data_dirs[2]}" --arg tor "${data_dirs[3]}" --arg d "${data_dirs[4]}" \
    '.monero.data_dir=$m | .tari.data_dir=$t | .p2pool.data_dir=$p | .tor.data_dir=$tor | .dashboard.data_dir=$d' \
    "$original/config.json" >"$moved/config.json"
chmod 600 "$moved/config.json"
identity() {
    docker inspect monerod tari | jq -ceS '[.[] | {id:.Id, started:.State.StartedAt, running:.State.Running}] | select(length == 2 and all(.[]; .running and (.id | length > 0) and (.started | length > 0)))'
}
before=""
for _ in $(seq 1 60); do
    if before=$(identity); then break; fi
    sleep 2
done
[ -n "$before" ] || {
    printf '%s\n' 'chain directory move: both nodes did not become running' >&2
    exit 1
}
(cd "$moved" && PITHEAD_STEAL_CONTROL_UNITS=1 ./pithead render)
for service in monerod tari; do
    docker compose --project-directory "$moved" config --format json |
        jq -e --arg d "$moved/" --arg s "$service" \
            '[.services[$s].volumes[] | select(.type == "bind") | .source | startswith($d)] | all(. == false)' >/dev/null
done
(cd "$moved" && PITHEAD_PULL=never ./pithead up)
for _ in $(seq 1 6); do
    [ "$(identity)" = "$before" ] || {
        printf '%s\n' 'chain directory move: identity or start time changed' >&2
        exit 1
    }
    sleep 2
done
(cd "$original" && PITHEAD_STEAL_CONTROL_UNITS=1 ./pithead render && PITHEAD_PULL=never ./pithead up)
[ "$(identity)" = "$before" ] || {
    printf '%s\n' 'chain directory move: restoration changed node identity' >&2
    exit 1
}
printf '%s\n' 'chain directory move: both container IDs and start times preserved'
