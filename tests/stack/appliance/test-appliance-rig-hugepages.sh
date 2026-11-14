# shellcheck shell=bash
: "${STACK_SUITE:?is unset: this file is a tests/stack/run.sh fragment, not a script — run tests/stack/run.sh}"

echo "== unit: pithead-hugepages role fork — a rig reserves nothing (#4010) =="
RH="$SANDBOX/hugepages-role"
mkdir -p "$RH"
printf 'MemTotal:       16250000 kB\n' >"$RH/meminfo-16g"
printf 'MemTotal:       4000000 kB\n' >"$RH/meminfo-4g"
printf 'rig\n' >"$RH/role-rig"
printf 'both\n' >"$RH/role-both"
printf 'pithead\n' >"$RH/role-coordinator"

hg_role_boot() { # <role> <meminfo> -> the boot's console text, after resetting the fixture pool
    printf '3072\n' >"$RH/nr_hugepages"
    rm -f "$RH/marker"
    (
        export PITHEAD_MEMINFO="$2" PITHEAD_NR_HUGEPAGES_FILE="$RH/nr_hugepages" \
            PITHEAD_HUGEPAGES_MARKER="$RH/marker" PITHEAD_MACHINE_ROLE_FILE="$RH/role-$1"
        # shellcheck disable=SC1091
        source "$ROOT/os/overlay/pithead-hugepages"
        main
    )
}

out=$(hg_role_boot rig "$RH/meminfo-16g")
assert_eq "rig on the supported machine releases even the full baked pool (#4010)" "$(cat "$RH/nr_hugepages")" "0"
assert_eq "rig boot writes no degraded marker (#4010)" "$(cat "$RH/marker" 2>/dev/null || echo absent)" "absent"
assert_contains "rig boot names who sizes the pool instead (#4010)" "$out" "RigForge sizes the pool"
assert_not_contains "rig boot carries none of the coordinator's degraded prose (#4010)" "$out" "below the supported 16 GB"

out=$(hg_role_boot rig "$RH/meminfo-4g")
assert_eq "rig on a 4 GiB machine reserves nothing (#4010)" "$(cat "$RH/nr_hugepages")" "0"
assert_eq "a small rig writes no degraded marker either (#4010)" "$(cat "$RH/marker" 2>/dev/null || echo absent)" "absent"
assert_not_contains "a small rig is never told its stack will not run (#4010)" "$out" "will not run reliably"

out=$(hg_role_boot both "$RH/meminfo-4g")
assert_eq "role=both keeps the coordinator tier exactly (#4010)" "$(cat "$RH/nr_hugepages")" "0"
assert_contains "role=both still gets the coordinator's degraded words (#4010)" "$out" "far below the supported 16 GB"

out=$(hg_role_boot coordinator "$RH/meminfo-16g")
assert_eq "role=pithead keeps the full baked pool untouched (#4010)" "$(cat "$RH/nr_hugepages")" "3072"
assert_eq "role=pithead says nothing (#4010)" "$out" ""
