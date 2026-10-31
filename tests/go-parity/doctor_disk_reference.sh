#!/usr/bin/env bash
set -Eeuo pipefail

root=$1
operation=$2
directory=$3
shift 3
export PITHEAD_IMPL=bash
export NO_COLOR=1

# shellcheck source=/dev/null
source "$root/pithead"
cd "$directory"

case "$operation" in
component)
    disk_component_gib "$@"
    exit
    ;;
mount)
    mount=$(disk_fs_mount "$1")
    printf '%s' "$mount"
    exit
    ;;
esac

rows=$(/usr/bin/mktemp)
trap '/bin/rm -f "$rows"' EXIT
export DR_JSON_FILE="$rows"
check_disk_grouped "$@" >&2
/bin/cat "$rows"
