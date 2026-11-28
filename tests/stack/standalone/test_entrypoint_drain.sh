#!/usr/bin/env bash
set -euo pipefail
service=${1:?service required}
image=${2:?image tag required}
case "$service" in
p2pool | xmrig-proxy) ;;
*)
    echo "Unknown wrapped service: $service" >&2
    exit 2
    ;;
esac
echo "== $service: the wrapper entrypoint drains the daemon's last lines and forwards stop =="
fixture=$(mktemp -d "${TMPDIR:?}/pithead-entrypoint-drain.XXXXXX")
name="pithead-drain-$service-$$"
trap 'docker rm -f "$name" >/dev/null 2>&1 || :; rm -rf -- "$fixture"' EXIT
chmod 755 "$fixture"
fail=0
check() {
    if [ "$2" = "$3" ]; then
        printf '  ok   %s\n' "$1"
    else
        printf '  FAIL %s: got [%s], want [%s]\n' "$1" "$2" "$3"
        fail=1
    fi
}

want=$(docker run --rm --network none --entrypoint "$service" "$image" --help 2>&1 | tail -n 1 || :)
got=$(docker run --rm --network none "$image" --help 2>&1 | tail -n 1 || :)
check "the real daemon's last --help line reaches the container log" "$got" "$want"

cat >"$fixture/burst" <<'STUB'
#!/bin/sh
i=0
while [ "$i" -lt 20000 ]; do
    echo "burst line $i"
    i=$((i + 1))
done
printf 'final line before exit'
exit 3
STUB
chmod 755 "$fixture/burst"
docker run --name "$name" --network none -v "$fixture/burst:/usr/local/bin/$service:ro" "$image" >/dev/null 2>&1 || :
check "the daemon's exit status is the container's" "$(docker inspect -f '{{.State.ExitCode}}' "$name")" 3
check "the line printed just before exit is in the log" "$(docker logs "$name" 2>&1 | tail -n 1)" "final line before exit"
check "no burst line is lost" "$(docker logs "$name" 2>&1 | grep -c '^burst line ')" 20000
docker rm -f "$name" >/dev/null

cat >"$fixture/stop" <<'STUB'
#!/bin/sh
trap 'echo "stopping on TERM"; exit 0' TERM
echo "daemon ready"
while :; do sleep 1; done
STUB
chmod 755 "$fixture/stop"
docker run -d --name "$name" --network none -v "$fixture/stop:/usr/local/bin/$service:ro" "$image" >/dev/null
for _ in $(seq 1 50); do
    docker logs "$name" 2>&1 | grep -q 'daemon ready' && break
    sleep 0.2
done
start=$(date +%s)
docker stop -t 30 "$name" >/dev/null
elapsed=$(($(date +%s) - start))
check "docker stop reaches the daemon before the kill timeout" "$([ "$elapsed" -lt 20 ] && echo yes || echo "no (${elapsed}s)")" yes
check "the stopped daemon's exit status is the container's" "$(docker inspect -f '{{.State.ExitCode}}' "$name")" 0
check "the daemon's shutdown line is in the log" "$(docker logs "$name" 2>&1 | tail -n 1)" "stopping on TERM"
check "the proc link names the daemon" "$(docker run --rm --network none -v "$fixture/stop:/usr/local/bin/$service:ro" --entrypoint sh "$image" -c "/usr/local/bin/entrypoint.sh >/dev/null 2>&1 & sleep 2; tr '\\0' ' ' </tmp/$service.proc/cmdline")" "/bin/sh /usr/local/bin/$service "
exit "$fail"
