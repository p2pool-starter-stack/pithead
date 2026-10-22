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
    hostname) printf "coordinator\n" ;;
    *getent*)
        case "$*" in
        *kvm-share-unresolved.invalid*) return 0 ;;
        *kvm-share-coordinator.invalid*)
            grep -q kvm-share-coordinator.invalid "$scratch/hosts" || return 0
            [ "$scenario" != bad-hostname ] || return 0
            [ "$scenario" != wrong-address ] || {
                printf '192.0.2.9\n'
                return 0
            }
            ;;
        esac
        printf '192.0.2.2\n'
        ;;
    *mount*)
        local guest_cmd="${1//\/data\/rig-share-hosts.original/$scratch/hosts.original}"
        guest_cmd="${guest_cmd//\/etc\/hosts/$scratch/hosts}"
        bash -c '
            fixture_root="$2" fixture_case="$3"
            mount() {
                if [ "$2" = remount,ro ] && [ "$fixture_case" = hosts-remount-failure ] &&
                    [ ! -f "$fixture_root/ro-failed" ]; then
                    touch "$fixture_root/ro-failed"
                    return 1
                fi
                printf "%s\n" "${2#remount,}" >"$fixture_root/root-mode"
            }
            findmnt() { cat "$fixture_root/root-mode"; }
            cp() {
                [ "$fixture_case" != hosts-copy-failure ] || return 1
                command cp "$@"
            }
            printf() {
                if [ "$fixture_case" = hosts-append-failure ] && [ "$1" = "%s %s\n" ]; then return 1; fi
                command printf "$@"
            }
            eval "$1"
        ' _ "$guest_cmd" "$scratch" "$scenario"
        ;;
    *jq*) bash -c "${1//\/data\/rigforge\/config.json/$scratch/config.json}" ;;
    *) fail "unexpected guest command" ;;
    esac
}
curl() {
    local arm reads accepted rejected=0 invalid=0 rate=250 online=online other=1 coordinator=coordinator
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
        wrong-coordinator) coordinator=foreign ;;
        missing-coordinator) coordinator=absent ;;
        string-coordinator) other='"1"' ;;
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
        --argjson rate "$rate" --arg online "$online" --argjson other "$other" --arg coordinator "$coordinator" \
        '{workers:[{name:"kvm-rig-share",accepted:$accepted,rejected:$rejected,invalid:$invalid,h10:$rate,status:$online},
        {name:$coordinator,accepted:$other}] | map(select(.name != "absent"))}'
}
run_case() {
    local scenario="$1" expected="$2" result=0
    local VM=fixture DISK="$scratch/rig.img" SERIAL="$scratch/rig.log" ip=192.0.2.1
    local RIG_SHARE_WINDOW_SEC=7
    rm -f "$scratch/hosts.original" "$scratch/ro-failed" "$scratch"/cookie.*
    printf "original hosts\n" >"$scratch/hosts"
    printf "ro\n" >"$scratch/root-mode"
    for file in pass fail teardown pools; do : >"$scratch/$file"; done
    for file in time arm reads; do printf '0\n' >"$scratch/$file"; done
    rig_share_leg image node 1 2 user pass tari 3 "$ip" 2>"$scratch/stderr" || result=$?
    [ "$result" = "$expected" ] || fail "$scenario returned $result, expected $expected"
    [ "$(wc -l <"$scratch/teardown")" -eq 2 ] || fail "$scenario leaked coordinator"
    [ "$(cat "$scratch/hosts")" = "original hosts" ] || fail "$scenario leaked hosts fixture"
    [ "$(cat "$scratch/root-mode")" = ro ] || fail "$scenario left root writable"
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
for scenario in stale stale-return rejected invalid transient-rejected zero-rate offline no-coordinator wrong-coordinator missing-coordinator string-coordinator unreadable missing-rate missing-worker wrong-pool extra-pool bad-hostname wrong-address hosts-copy-failure hosts-append-failure hosts-remount-failure; do
    run_case "$scenario" 1
done
printf 'selftest-rig-share: 22 scenarios passed\n'
