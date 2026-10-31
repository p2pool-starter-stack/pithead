#!/usr/bin/env bash
set -Eeuo pipefail

root=$1
operation=$2
meminfo=$3
marker=$4
appliance=$5

export NO_COLOR=1
export PITHEAD_IMPL=bash
export PITHEAD_MEMINFO="$meminfo"
export PITHEAD_HUGEPAGES_MARKER="$marker"
export PITHEAD_APPLIANCE="$appliance"

# shellcheck source=/dev/null
source "$root/pithead"

free_ram_reference() {
    local body starts ends
    starts=$(grep -c '^[[:space:]]*local mem_avail_kb mem_avail_mb$' "$root/lib/pithead/06-doctor.sh")
    ends=$(sed -n '/^[[:space:]]*local mem_avail_kb mem_avail_mb$/,/^[[:space:]]*# --- Network:/p' "$root/lib/pithead/06-doctor.sh" | grep -c '^        fi$')
    [ "$starts" = 1 ] && [ "$ends" = 1 ]
    body=$(awk '/^[[:space:]]*local mem_avail_kb mem_avail_mb$/{found=1} found{print} found && $0 == "        fi"{exit}' "$root/lib/pithead/06-doctor.sh")
    # shellcheck disable=SC2016
    body=${body/' /proc/meminfo '/' "$PITHEAD_MEMINFO" '}
    eval "$body"
}

clock_reference() {
    local body starts ends
    # shellcheck disable=SC2016
    starts=$(grep -c '^[[:space:]]*case "$(clock_sync_status)" in$' "$root/lib/pithead/06-doctor.sh")
    # shellcheck disable=SC2016
    ends=$(sed -n '/^[[:space:]]*case "$(clock_sync_status)" in$/,/^[[:space:]]*esac$/p' "$root/lib/pithead/06-doctor.sh" | grep -c '^    esac$')
    [ "$starts" = 1 ] && [ "$ends" = 1 ]
    body=$(awk '/^[[:space:]]*case "\$\(clock_sync_status\)" in$/{found=1} found{print} found && $0 == "    esac"{exit}' "$root/lib/pithead/06-doctor.sh")
    eval "$body"
}

if [ "$operation" = decision ]; then
    hugepages_decision_pages
    exit
fi
if [ "$operation" = clock-status ]; then
    clock_sync_status
    exit
fi

rows=$(mktemp)
trap 'rm -f "$rows"' EXIT
export DR_JSON_FILE="$rows"

case "$operation" in
reserved) check_hugepages_reserved >&2 ;;
degraded) check_hugepages_degraded >&2 ;;
available) free_ram_reference >&2 ;;
clock) clock_reference >&2 ;;
*) exit 64 ;;
esac
cat "$rows"
