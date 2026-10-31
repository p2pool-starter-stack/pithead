#!/usr/bin/env bash
set -Eeuo pipefail

root=$1
operation=$2
export PITHEAD_APPLIANCE=$3
directory=$4
export PITHEAD_IMPL=bash
export NO_COLOR=1

# shellcheck source=/dev/null
source "$root/pithead"
cd "$directory"
rows=$(/usr/bin/mktemp)
trap '/bin/rm -f "$rows"' EXIT
export DR_JSON_FILE="$rows"

case "$operation" in
release) check_release_verification >&2 ;;
daemon)
    source_file="$root/lib/pithead/06-doctor.sh"
    start='    if [ "$(container_engine)" = "podman" ]; then'
    end='    fi'
    [ "$(/usr/bin/grep -Fxc "$start" "$source_file")" = 1 ]
    body=$(/usr/bin/awk -v start="$start" -v end="$end" \
        '$0 == start { found=1 } found { print } found && $0 == end { exit }' "$source_file")
    [ -n "$body" ]
    [ "$(printf '%s\n' "$body" | /usr/bin/grep -Fxc "$end")" = 1 ]
    eval "$body" >&2
    ;;
*) exit 64 ;;
esac
/bin/cat "$rows"
