#!/usr/bin/env bash
set -euo pipefail
payload_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
cd /data/pithead
export TMPDIR="${TMPDIR:-/data/tmp}"
mkdir -p "$TMPDIR"
fixture=$(mktemp -d)
project="engine-contract-$$"
compose="$fixture/compose.json"
cleanup() {
    local rc=$?
    docker compose -p "$project" -f "$compose" down >/dev/null 2>&1 || rc=1
    rm -rf "$fixture"
    exit "$rc"
}
trap cleanup EXIT
image=$(docker inspect -f '{{.Config.Image}}' caddy)
mkdir -p "$fixture/tor"
jq -n --arg image "$image" --arg mount "$fixture/tor:/var/lib/tor" \
    '{services:{probe:{image:$image,entrypoint:["sh","-c","sleep 300"],network_mode:"none",volumes:[$mount],healthcheck:{test:["CMD","true"],interval:"1s"}}}}' >"$compose"
docker compose -p "$project" -f "$compose" up -d >/dev/null
container=$(docker compose -p "$project" -f "$compose" ps -aq)
[ -n "$container" ]
name=$(docker inspect -f '{{.Name}}' "$container")
name=${name#/}
for state in running stopped; do
    if [ "$state" = stopped ]; then docker stop "$container" >/dev/null; fi
    python3 "$payload_dir/engine-contract.py" run "$payload_dir/current.json" "$project" "$compose" "$name"
done
set +e
python3 "$payload_dir/engine-contract.py" run "$payload_dir/rc3.json" "$project" "$compose" "$name" >"$fixture/rc3-result" 2>&1
rc=$?
set -e
[ "$rc" -ne 0 ] && grep -q 'status=restarting.*exit 125' "$fixture/rc3-result" || {
    echo 'engine census original-source negative control did not reproduce Podman exit 125' >&2
    exit 1
}
echo 'engine census RC3 negative control: RED (Podman rejects status=restarting)'
export ENGINE_CONTRACT_WORK="$payload_dir"
bash "$payload_dir/container-restart-leg.sh"
echo 'appliance engine contract: PASS'
