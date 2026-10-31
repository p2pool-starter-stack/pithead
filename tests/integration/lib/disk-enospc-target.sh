#!/usr/bin/env bash
set -uo pipefail

ddir=$(realpath -e -- "$1") || exit 1
[ -d "$ddir" ] || exit 1
timeout -k 5 15 bash -c 'source ./pithead; declare -F _data_dir_is_broad_root >/dev/null || exit 2; ! _data_dir_is_broad_root "$1"' bash "$ddir" || exit 1
bind_source=$(timeout -k 5 15 docker inspect dashboard --format '{{json .Mounts}}' |
    jq -er '[.[] | select(.Type == "bind" and .Destination == "/data")] | select(length == 1) | .[0].Source') || exit 1
[ "$(realpath -e -- "$bind_source")" = "$ddir" ] || exit 1
covering_row() {
    findmnt -J -T "$ddir" -o ID,SOURCE,FSTYPE,TARGET | jq -ceS '.filesystems | select(length == 1) | .[0]'
}
mount_row() {
    covering_row | jq -ceS --arg target "$ddir" 'select(.target == $target)'
}
is_owned() {
    [ -n "$1" ] || return 1
    jq -e --arg source "$identity" 'select(.source == $source and .fstype == "tmpfs")' >/dev/null <<<"$1"
}
baseline=$(covering_row) || exit 1
uuid=$(cat /proc/sys/kernel/random/uuid) || exit 1
[[ "$uuid" =~ ^[a-f0-9-]{36}$ ]] || exit 1
identity="pithead-enospc-$uuid"
owned=""
attempted=0

wait_db() {
    local want=$1 i value
    for ((i = 0; i < 18; i++)); do
        value=$(curl -fsS --max-time 5 http://127.0.0.1:8000/api/state | jq -r '.db_healthy') || value=""
        [ "$value" != "$want" ] || return 0
        sleep 5
    done
    return 1
}
cleanup() {
    local rc=$? current restored=0
    trap - EXIT
    if [ "$attempted" = 1 ]; then
        current=$(mount_row) || current=""
        if is_owned "$current" && { [ -z "$owned" ] || [ "$current" = "$owned" ]; }; then
            if timeout -k 5 15 sudo -n umount -- "$ddir" &&
                [ "$(covering_row)" = "$baseline" ]; then
                restored=1
            fi
        elif [ "$(covering_row)" = "$baseline" ]; then
            restored=1
        fi
        if [ "$restored" = 1 ]; then
            echo 'ENOSPC mount restored'
            if timeout -k 5 30 docker compose restart dashboard && wait_db true; then
                echo 'ENOSPC dashboard recovered'
            else
                echo 'ENOSPC dashboard recovery failed'
                rc=1
            fi
        else
            echo 'ENOSPC cleanup failed: mount ownership or baseline unverified'
            rc=1
        fi
    fi
    exit "$rc"
}
trap cleanup EXIT
attempted=1
mount_rc=0
timeout -k 5 15 sudo -n mount -t tmpfs -o size=1m,uid=1000,gid=1000 "$identity" "$ddir" || mount_rc=$?
current=$(mount_row) || current=""
if is_owned "$current"; then
    owned=$current
else
    echo 'ENOSPC mount not owned'
    exit 1
fi
[ "$mount_rc" = 0 ] || exit 1

if ! timeout -k 5 15 python3 - "$ddir" <<'PY'; then
import errno
import os
import sys

fd = os.open(os.path.join(sys.argv[1], '.itest-fill'), os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600)
try:
    for _ in range(512):
        os.write(fd, bytes(8192))
except OSError as exc:
    if exc.errno != errno.ENOSPC:
        raise
else:
    raise SystemExit('ENOSPC not reached within 4 MiB')
finally:
    os.close(fd)
PY
    exit 1
fi
echo 'ENOSPC fill confirmed'
timeout -k 5 30 docker compose restart dashboard || exit 1
wait_db false || exit 1
echo 'ENOSPC db unhealthy confirmed'
