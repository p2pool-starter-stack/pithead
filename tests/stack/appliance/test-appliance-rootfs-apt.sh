#!/usr/bin/env bash
: "${STACK_SUITE:?source this fragment through tests/stack/run.sh}"

echo "== unit: rootfs apt packages occupy one cleaned image layer (#2820) =="
apt_steps=()
instruction=""
continuation=0
while IFS= read -r line || [ -n "$line" ]; do
    if [[ "$line" == RUN\ * ]]; then
        [[ "$instruction" == *apt-get* ]] && apt_steps+=("$instruction")
        instruction="$line"
    elif [ "$continuation" -eq 1 ]; then
        instruction+=" $line"
    else
        [[ "$instruction" == *apt-get* ]] && apt_steps+=("$instruction")
        instruction=""
    fi
    continuation=0
    [[ "$line" == *\\ ]] && continuation=1
done <"$ROOT/os/rootfs/Dockerfile"
[[ "$instruction" == *apt-get* ]] && apt_steps+=("$instruction")

assert_eq "one apt RUN layer in the appliance rootfs" "${#apt_steps[@]}" "1"
apt_step="${apt_steps[0]:-}"
assert_contains "the apt layer refreshes its index" "$apt_step" "apt-get update"
assert_contains "the apt layer installs packages" "$apt_step" "apt-get install -y --no-install-recommends"
assert_contains "the apt layer includes the RigForge toolchain" "$apt_step" "linux-cpupower msr-tools"
assert_contains "the apt layer selects both RAUC packages" "$apt_step" 'updater_packages="rauc rauc-service"'
assert_contains "the apt layer removes indexes before committing" "$apt_step" 'rm -rf /var/lib/apt/lists/*'
assert_contains "the apt layer removes package archives before committing" "$apt_step" '/var/cache/apt/archives/*.deb'
unset apt_steps apt_step instruction continuation line
