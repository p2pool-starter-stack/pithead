#!/usr/bin/env bash
set -Eeuo pipefail

root=$1
operation=$2
appliance=$3
os_type=$5

export NO_COLOR=1
export PITHEAD_IMPL=bash
export PITHEAD_APPLIANCE="$appliance"
export PITHEAD_CPUINFO=$4

# shellcheck source=/dev/null
source "$root/pithead"
# shellcheck disable=SC2153
[ "$OS_TYPE" = "$os_type" ]

extract_block() {
    local start=$1 end=$2 body starts ends
    starts=$(/usr/bin/grep -c "$start" "$root/lib/pithead/06-doctor.sh")
    ends=$(/usr/bin/sed -n "/$start/,/$end/p" "$root/lib/pithead/06-doctor.sh" | /usr/bin/grep -c "$end")
    [ "$starts" = 1 ] && [ "$ends" = 1 ]
    body=$(/usr/bin/awk -v start="$start" -v end="$end" \
        '$0 ~ start { found=1 } found { print } found && $0 ~ end { exit }' \
        "$root/lib/pithead/06-doctor.sh")
    printf '%s\n' "$body"
}

prepare_cpu_reference() {
    local function_body
    function_body=$(declare -f cpu_has_avx2)
    [ "$(printf '%s' "$function_body" | /usr/bin/grep -c '/proc/cpuinfo')" = 1 ]
    function_body=${function_body/cpu_has_avx2 ()/cpu_reference_has_avx2 ()}
    # shellcheck disable=SC2016
    function_body=${function_body/'/proc/cpuinfo'/'"$PITHEAD_CPUINFO"'}
    eval "$function_body"
}

cpu_reference() {
    local row_body
    prepare_cpu_reference
    row_body=$(extract_block '^[[:space:]]*if cpu_has_avx2; then$' '^    fi$')
    row_body=${row_body/cpu_has_avx2/cpu_reference_has_avx2}
    eval "$row_body"
}

boot_reference() {
    local body
    body=$(extract_block '^[[:space:]]*if docker_boot_enabled; then$' '^        fi$')
    eval "$body"
}

dependencies_reference() {
    local body starts ends
    starts=$(/usr/bin/grep -c '^[[:space:]]*if command -v jq ' "$root/lib/pithead/06-doctor.sh")
    ends=$(/usr/bin/grep -c '^[[:space:]]*check_release_verification$' "$root/lib/pithead/06-doctor.sh")
    [ "$starts" = 1 ] && [ "$ends" = 1 ]
    body=$(/usr/bin/awk \
        '/^[[:space:]]*if command -v jq / { found=1 } found && /^[[:space:]]*check_release_verification$/ { exit } found { print }' \
        "$root/lib/pithead/06-doctor.sh")
    eval "$body"
}

if [ "$operation" = engine ]; then
    container_engine
    exit
fi

rows=$(/usr/bin/mktemp)
trap '/bin/rm -f "$rows"' EXIT
export DR_JSON_FILE="$rows"

case "$operation" in
boot) boot_reference >&2 ;;
boot-enabled) docker_boot_enabled ;;
cpu) cpu_reference >&2 ;;
cpu-has-avx2)
    prepare_cpu_reference
    cpu_reference_has_avx2
    ;;
dependencies) dependencies_reference >&2 ;;
*) exit 64 ;;
esac
/bin/cat "$rows"
