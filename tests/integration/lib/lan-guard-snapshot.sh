#!/usr/bin/env bash
set -uo pipefail
port="${1:-}"
case "$port" in
18081 | 18083) container=monerod ;;
18142) container=tari ;;
*) exit 2 ;;
esac
printf 'port=%s container=%s\n' "$port" "$container"
if state=$(timeout --kill-after=1 3 docker inspect -f '{{.State.Running}} {{.State.ExitCode}} {{.RestartCount}}' "$container" 2>/dev/null) &&
    [[ "$state" =~ ^(true|false)\ [0-9]+\ [0-9]+$ ]]; then
    printf 'running_exit_restarts=%s\n' "$state"
else
    printf 'container_state=unavailable\n'
fi
pid=$(timeout --kill-after=1 3 docker inspect -f '{{.State.Pid}}' "$container" 2>/dev/null) || pid=''
if [[ "$pid" =~ ^[1-9][0-9]*$ ]]; then
    if sockets=$(timeout --kill-after=1 3 sudo -n nsenter -t "$pid" -n ss -H -ltn "sport = :$port" 2>/dev/null); then
        if [ -n "$sockets" ]; then printf 'node_listener=present\n'; else printf 'node_listener=absent\n'; fi
    else
        printf 'node_listener=unavailable\n'
    fi
else
    printf 'node_listener=unavailable\n'
fi
if timeout --kill-after=1 3 bash -c 'source ./pithead >/dev/null 2>&1 && lan_guard_enforced "$1"' -- "$port" >/dev/null 2>&1; then
    printf 'guard=enforced\n'
else
    printf 'guard=not-enforced-or-unavailable\n'
fi
if unit=$(timeout --kill-after=1 3 systemctl show pithead-lan-check.service \
    -p LoadState -p ActiveState -p SubState -p Result -p ExecMainStatus \
    -p ExecMainStartTimestampMonotonic -p ExecMainExitTimestampMonotonic 2>/dev/null); then
    printf '%s\n' "$unit" | grep -E '^(LoadState|ActiveState|SubState|Result|ExecMainStatus|ExecMainStartTimestampMonotonic|ExecMainExitTimestampMonotonic)=[a-zA-Z0-9-]+$'
else
    printf 'lan_check=unavailable\n'
fi
