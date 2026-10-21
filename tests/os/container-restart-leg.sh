#!/usr/bin/env bash
set -euo pipefail

cd /data/pithead
work=$(mktemp -d)
restore_caddy() {
    local rc=0
    podman rm -f caddy >/dev/null 2>&1 || rc=1
    timeout 90 ./pithead up >/dev/null 2>&1 || rc=1
    return "$rc"
}
on_exit() {
    local rc=$?
    restore_caddy || {
        echo 'restart detection leg: emergency caddy restoration failed' >&2
        rc=1
    }
    rm -f .pithead-baseline
    rm -rf "$work"
    exit "$rc"
}
trap on_exit EXIT

image=$(podman inspect -f '{{.ImageName}}' caddy)
podman inspect caddy | jq -r '.[0].Config.Labels | to_entries[] | "\(.key)=\(.value)"' >"$work/caddy.labels"
cp pithead .pithead-baseline
# shellcheck disable=SC2016
sed -e 's/restarting_names=$(container_restarting_names) || restart_read_ok=0/restarting_names=""/' \
    -e '/^        check_container_restarts$/s/check_container_restarts/:/' \
    .pithead-baseline >"$work/pithead-baseline.tmp"
mv "$work/pithead-baseline.tmp" .pithead-baseline
chmod +x .pithead-baseline

podman rm -f caddy >/dev/null
podman run -d --pull=never --name caddy --restart always --label-file "$work/caddy.labels" \
    --entrypoint sh "$image" -c 'sleep 1; exit 1' >/dev/null

deadline=$((SECONDS + 30))
observed=0
previous=$(podman inspect -f '{{.RestartCount}}' caddy)
while [ "$SECONDS" -lt "$deadline" ]; do
    sleep 1
    current=$(podman inspect -f '{{.RestartCount}}' caddy)
    if [ "$current" -gt "$previous" ]; then
        observed=1
        break
    fi
    previous=$current
done
[ "$observed" -eq 1 ] || {
    echo 'restart detection leg: caddy did not advance its restart count' >&2
    exit 1
}

running_deadline=$((SECONDS + 10))
while [ "$SECONDS" -lt "$running_deadline" ] && [ "$(podman inspect -f '{{.State.Status}}' caddy)" != running ]; do
    sleep 0.1
done
if ! timeout 30 ./.pithead-baseline status >"$work/baseline-status" 2>&1 ||
    grep -Eq 'caddy +restarting' "$work/baseline-status"; then
    echo 'restart detection leg: baseline negative control did not reproduce the missed crash loop' >&2
    exit 1
fi

status_rc=0
timeout 30 ./pithead status >"$work/status" 2>&1 || status_rc=$?
if [ "$status_rc" -ne 1 ] || ! grep -Eq 'caddy +restarting' "$work/status"; then
    echo 'restart detection leg: status did not fail and name restarting caddy' >&2
    exit 1
fi

doctor_rc=0
timeout 30 ./pithead doctor >"$work/doctor" 2>&1 || doctor_rc=$?
if [ "$doctor_rc" -ne 1 ] || ! grep -Fq 'caddy restarted during the health check' "$work/doctor"; then
    echo 'restart detection leg: doctor did not fail and name restarting caddy' >&2
    exit 1
fi

if ! restore_caddy >"$work/restore" 2>&1; then
    echo 'restart detection leg: restoring caddy failed' >&2
    exit 1
fi
recovered=0
deadline=$((SECONDS + 90))
while [ "$SECONDS" -lt "$deadline" ]; do
    if timeout 30 ./pithead status >"$work/recovered-status" 2>&1; then
        recovered=1
        break
    fi
    sleep 3
done
[ "$recovered" -eq 1 ] || {
    echo 'restart detection leg: status did not recover after restoring caddy' >&2
    exit 1
}

trap - EXIT
rm -f .pithead-baseline
rm -rf "$work"
echo 'restart detection leg: PASS'
