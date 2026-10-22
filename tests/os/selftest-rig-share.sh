#!/usr/bin/env bash
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=tests/os/rig-share-leg.sh
source "${RIG_SHARE_LEG_UNDER_TEST:-$HERE/rig-share-leg.sh}"
scratch=$(mktemp -d)
trap 'rm -rf "$scratch"' EXIT
fail() {
    printf 'FAIL: %s\n' "$*" >&2
    exit 1
}
ok() { printf '%s\n' "$*" >>"$scratch/pass"; }
bad() { printf '%s\n' "$*" >>"$scratch/fail"; }
info() { :; }
kvm_preflight() { return 0; }
_provision_remote_node_coordinator() {
    ip=192.0.2.2 dash_user=fixture dash_pass=fixture
}
virsh() { printf '%s\n' "$*" >>"$scratch/teardown"; }
date() {
    local tick
    tick=$(cat "$scratch/time")
    printf '%s\n' "$((tick + 1))" >"$scratch/time"
    printf '%s\n' "$tick"
}
sleep() { :; }
_setup_again_boot() {
    printf '%s\n' "$(($(cat "$scratch/arm") + 1))" >"$scratch/arm"
    printf '0\n' >"$scratch/reads"
}
_setup_again_session() {
    jar=$(mktemp "$scratch/cookie.XXXXXX")
}
_setup_again_rig_submit() {
    printf '%s\n' "$2" >>"$scratch/pools"
    local configured="$2"
    [ "$scenario" != wrong-pool ] || configured=wrong.invalid:3333
    jq -n --arg pool "$configured" '{pools:[{url:$pool}]}' >"$scratch/config.json"
    if [ "$scenario" = extra-pool ]; then
        jq '.pools += [{url:"fallback.invalid:3333"}]' "$scratch/config.json" >"$scratch/extra.json"
        mv "$scratch/extra.json" "$scratch/config.json"
    fi
    printf 'fixture-card coordinator\n'
}
_rig_mining_up() { return 0; }
_ssh() {
    case "$*" in
    *getent*)
        case "$*" in
        *kvm-share-unresolved.invalid*) return 0 ;;
        *kvm-share-coordinator.invalid*)
            [ -f "$scratch/hosts" ] || return 0
            [ "$scenario" != bad-hostname ] || return 0
            [ "$scenario" != wrong-address ] || {
                printf '192.0.2.9\n'
                return 0
            }
            ;;
        esac
        printf '192.0.2.2\n'
        ;;
    *mount*) touch "$scratch/hosts" ;;
    *jq*) bash -c "${1//\/data\/rigforge\/config.json/$scratch/config.json}" ;;
    *) fail "unexpected guest command" ;;
    esac
}
curl() {
    local arm reads accepted rejected=0 invalid=0 rate=250 online=online other=1
    arm=$(cat "$scratch/arm")
    reads=$(cat "$scratch/reads")
    printf '%s\n' "$((reads + 1))" >"$scratch/reads"
    accepted=$((arm * 10))
    if [ "$reads" -gt 0 ]; then
        accepted=$((accepted + 1))
        case "$scenario" in
        stale) accepted=$((arm * 10)) ;;
        stale-return) [ "$arm" != 3 ] || accepted=$((arm * 10)) ;;
        rejected) rejected=1 ;;
        invalid) invalid=1 ;;
        zero-rate) rate=0 ;;
        offline) online=offline ;;
        no-coordinator) other=0 ;;
        unreadable)
            printf '{'
            return 0
            ;;
        missing-rate) rate=null ;;
        missing-worker)
            printf '{"workers":[]}'
            return 0
            ;;
        transient-rejected) [ "$reads" != 1 ] || rejected=1 ;;
        esac
    fi
    jq -n --argjson accepted "$accepted" --argjson rejected "$rejected" --argjson invalid "$invalid" \
        --argjson rate "$rate" --arg online "$online" --argjson other "$other" \
        '{workers:[{name:"kvm-rig-share",accepted:$accepted,rejected:$rejected,invalid:$invalid,h10:$rate,status:$online},
        {name:"coordinator",accepted:$other}]}'
}
run_case() {
    local scenario="$1" expected="$2" result=0
    local VM=fixture DISK="$scratch/rig.img" SERIAL="$scratch/rig.log" ip=192.0.2.1
    local RIG_SHARE_WINDOW_SEC=7
    rm -f "$scratch/hosts" "$scratch"/cookie.*
    for file in pass fail teardown pools; do : >"$scratch/$file"; done
    for file in time arm reads; do printf '0\n' >"$scratch/$file"; done
    rig_share_leg image node 1 2 user pass tari 3 "$ip" 2>"$scratch/stderr" || result=$?
    [ "$result" = "$expected" ] || fail "$scenario returned $result, expected $expected"
    [ "$(wc -l <"$scratch/teardown")" -eq 2 ] || fail "$scenario leaked coordinator"
    [ "$VM" = fixture ] && [ "$ip" = 192.0.2.1 ] || fail "$scenario lost rig globals"
    [ -z "$(find "$scratch" -name 'cookie.*' -print)" ] || fail "$scenario leaked a session"
    if [ "$expected" = 0 ]; then
        [ "$(wc -l <"$scratch/fail")" -eq 0 ] || fail "$scenario reported failure"
        [ "$(cat "$scratch/pools")" = $'192.0.2.2:3333\nkvm-share-coordinator.invalid:3333\n192.0.2.2:3333' ] || fail 'retarget order changed'
        [ "$(grep -c 'fresh accepted shares' "$scratch/pass")" -eq 3 ] || fail 'missing strict share windows'
        grep -q 'unresolved hostname fails' "$scratch/pass" || fail 'missing hostname negative control'
    else
        [ -s "$scratch/fail" ] || fail "$scenario did not report failure"
    fi
}
run_case healthy 0
for scenario in stale stale-return rejected invalid transient-rejected zero-rate offline no-coordinator unreadable missing-rate missing-worker wrong-pool extra-pool bad-hostname wrong-address; do
    run_case "$scenario" 1
done
printf 'selftest-rig-share: 16 scenarios passed\n'
