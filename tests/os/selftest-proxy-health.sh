#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/appliance-proxy-health-leg.sh"
ok() { :; }
bad() { failed=$((failed + 1)); }
_ssh() {
    printf '%s\n' "$reply"
    return "$ssh_rc"
}
for mode in complete empty partial ssh-failure; do
    failed=0 ssh_rc=0 reply='PASS: native Quadlet proxy health proof complete'
    case "$mode" in
    empty) reply='' ;;
    partial) reply='PASS: native Quadlet proxy runs its real API health probe and reports healthy' ;;
    ssh-failure) ssh_rc=1 ;;
    esac
    phase_provision_proxy_health >/dev/null
    if [ "$mode" = complete ]; then
        [ "$failed" -eq 0 ]
    else
        [ "$failed" -eq 1 ]
    fi
done
echo 'PASS: proxy health leg rejects empty, partial and failed guest evidence'
fixture=$(mktemp -d)
trap 'rm -rf "$fixture"' EXIT
preflight_source=$(awk '/^proof_stage=preflight$/ { copy=1 } /^cleanup\(\) \{/ { exit } copy { print }' "$SCRIPT_DIR/proxy-quadlet-proof.sh")
proof_name="fixture-name"
for lookup_rc in 0 1 125; do
    proof_dir="$fixture/preflight"
    mkdir "$proof_dir"
    unit="$fixture/unit-not-present"
    podman() {
        echo "fixture lookup status $lookup_rc" >&2
        return "$lookup_rc"
    }
    rc=0
    (eval "$preflight_source") >"$fixture/preflight.log" 2>&1 || rc=$?
    if [ "$lookup_rc" -eq 1 ]; then
        [ "$rc" -eq 0 ]
        rm -f "$proof_dir/lookup.log"
        rmdir "$proof_dir"
    else
        [ "$rc" -ne 0 ]
        grep -qF "expected absent (1), got $lookup_rc" "$fixture/preflight.log"
        grep -qF "fixture lookup status $lookup_rc" "$fixture/preflight.log"
    fi
done
mkdir "$proof_dir"
touch "$unit"
rc=0
(eval "$preflight_source") >"$fixture/preflight.log" 2>&1 || rc=$?
[ "$rc" -ne 0 ]
grep -qF 'fixture unit already exists' "$fixture/preflight.log"
rm -f "$unit"
trap_source=$(awk '/^proof_stage=initialization$/ { copy=1 } /^cd / { exit } copy { print }' "$SCRIPT_DIR/proxy-quadlet-proof.sh")
rc=0
bash -euc "$trap_source
proof_stage=fixture-stage
false" >"$fixture/stage.log" 2>&1 || rc=$?
[ "$rc" -ne 0 ]
grep -qF 'native Quadlet proxy stage fixture-stage exited 1' "$fixture/stage.log"
echo 'PASS: proxy preflight and stage failures retain bounded diagnostics'
unit="$SCRIPT_DIR/../../os/quadlet/xmrig-proxy.container"
rewrite() {
    awk -v image=fixture-image -v name=fixture-name -f "$SCRIPT_DIR/proxy-quadlet-unit.awk" "$1"
}
rewrite "$unit" >"$fixture/output"
grep -qxF 'Network=none' "$fixture/output"
grep -qxF 'ContainerName=fixture-name' "$fixture/output"
grep -qxF 'Image=fixture-image' "$fixture/output"
! grep -Eq '^(After|Wants|Requires|IP|Volume|PublishPort)=' "$fixture/output"
cmp <(grep -E '^(Health|Notify=|TimeoutStartSec=)' "$unit") \
    <(grep -E '^(Health|Notify=|TimeoutStartSec=)' "$fixture/output")
for drift in missing duplicate dependency mount network host-mount host-network; do
    cp "$unit" "$fixture/drift"
    case "$drift" in
    missing) awk '!/^PublishPort=/' "$unit" >"$fixture/drift" ;;
    duplicate) printf 'PublishPort=3333:3333\n' >>"$fixture/drift" ;;
    dependency) printf 'Requires=live.service\n' >>"$fixture/drift" ;;
    mount) printf 'Volume=live-data:/data\n' >>"$fixture/drift" ;;
    host-mount) printf 'Mount=type=bind,source=/,destination=/host\n' >>"$fixture/drift" ;;
    host-network) awk '{ sub(/^PodmanArgs=.*/, "PodmanArgs=--network=host"); print }' "$unit" >"$fixture/drift" ;;
    network) printf 'Network=live-network\n' >>"$fixture/drift" ;;
    esac
    if rewrite "$fixture/drift" >/dev/null 2>&1; then
        echo "FAIL: proxy fixture accepted $drift drift" >&2
        exit 1
    fi
done
echo 'PASS: proxy fixture preserves health settings and refuses unsafe resource drift'
cleanup_source=$(awk '/^cleanup\(\) \{/ { copy=1 } copy { print } copy && /^\}/ { exit }' "$SCRIPT_DIR/proxy-quadlet-proof.sh")
for mode in success container service stop reload remove container-remove exists-error; do
    proof_dir="$fixture/scratch"
    mkdir "$proof_dir"
    unit="$fixture/proof.container"
    touch "$unit"
    proof_name="fixture-name"
    : "$proof_name"
    systemctl() {
        case "$1" in
        stop) [ "$mode" != stop ] ;;
        daemon-reload) [ "$mode" != reload ] ;;
        is-active)
            if [ "$mode" = service ]; then echo active; else echo inactive; fi
            ;;
        esac
    }
    podman() {
        if [ "$1" = container ]; then
            case "$mode" in
            container | container-remove) return 0 ;;
            exists-error) return 125 ;;
            *) return 1 ;;
            esac
        fi
        [ "$mode" != container-remove ]
    }
    rm() {
        if [ "$mode" = remove ] && [ "$1" = -f ]; then return 1; fi
        command rm "$@"
    }
    rc=0
    (
        eval "$cleanup_source"
        cleanup
    ) >"$fixture/cleanup.log" 2>&1 || rc=$?
    if [ "$mode" = success ]; then
        [ "$rc" -eq 0 ] && [ ! -e "$proof_dir" ] && [ ! -e "$unit" ]
    else
        [ "$rc" -ne 0 ]
    fi
    command rm -rf "$proof_dir" "$unit"
done
echo 'PASS: proxy fixture cleanup fails closed on surviving resources and command failures'
