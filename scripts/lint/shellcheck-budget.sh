#!/usr/bin/env bash
set -euo pipefail

if [ "$#" -lt 2 ]; then
    printf 'usage: %s <budget-seconds> <file> [command ...]\n' "$0" >&2
    exit 2
fi
budget=$1
file=$2
shift 2
if [[ ! "$budget" =~ ^[1-9][0-9]*$ ]]; then
    printf 'shellcheck-budget: budget must be a positive integer of seconds, got [%s]\n' "$budget" >&2
    exit 2
fi
if [ "$#" -eq 0 ]; then
    set -- shellcheck -x --severity=warning "$file"
fi
"$@" &
child=$!
while kill -0 "$child" 2>/dev/null; do
    if [ "$SECONDS" -ge "$budget" ]; then
        kill "$child" 2>/dev/null || true
        waited=0
        while kill -0 "$child" 2>/dev/null && [ "$waited" -lt 300 ]; do
            sleep 0.1
            waited=$((waited + 1))
        done
        kill -9 "$child" 2>/dev/null || true
        wait "$child" 2>/dev/null || true
        printf 'lint-sh: %s held the pinned shellcheck past its %s second budget; put "# shellcheck source=/dev/null" above source lines that follow another linted file\n' \
            "$file" "$budget" >&2
        exit 1
    fi
    sleep 0.1
done
wait "$child"
