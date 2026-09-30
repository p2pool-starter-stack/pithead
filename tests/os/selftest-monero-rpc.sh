#!/usr/bin/env bash
# Empty/partial guest output and nonzero SSH exits never credit a runtime proof.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=tests/os/appliance-monero-rpc-leg.sh
source "$SCRIPT_DIR/appliance-monero-rpc-leg.sh"
ok() { :; }
bad() { failed=$((failed + 1)); }
_ssh() {
    printf '%s\n' "$reply"
    return "$ssh_rc"
}
for mode in complete empty partial ssh-failure; do
    failed=0 ssh_rc=0 reply='PASS: native Quadlet RPC proof complete'
    case "$mode" in
    empty) reply='' ;;
    partial) reply='PASS: native Quadlet cold start uses the rendered monerod unit' ;;
    ssh-failure) ssh_rc=1 ;;
    esac
    phase_provision_monero_rpc >/dev/null
    if [ "$mode" = complete ]; then
        [ "$failed" -eq 0 ]
    else
        [ "$failed" -eq 1 ]
    fi
done
echo 'selftest-monero-rpc: 4 fail-closed tally cases passed'
# Each resource rewrite is mandatory and unique; renderer drift cannot retain live data.
fixture=$(mktemp -d)
trap 'rm -rf "$fixture"' EXIT
cat >"$fixture/unit" <<'UNIT'
[Unit]
After=tor.service
Requires=tor.service
[Container]
ContainerName=monerod
Image=monero-fixture
Network=mining.network
IP=fixture.26
Volume=live-data:/home/ubuntu/.bitmonero
Volume=live-template:/home/ubuntu/bitmonero.conf.template:ro
PublishPort=127.0.0.1:18081:18081
PublishPort=127.0.0.1:18083:18083
UNIT
rewrite() {
    awk -v data=fixture-data -v template=fixture-template -v image=fixture-image \
        -v network=fixture-network -v name=fixture-name -f "$SCRIPT_DIR/monero-quadlet-unit.awk" "$1"
}
rewrite "$fixture/unit" >"$fixture/output"
grep -qxF 'Volume=fixture-data:/home/ubuntu/.bitmonero' "$fixture/output"
! grep -q 'live-' "$fixture/output"
for drift in missing duplicate readonly publication dependency; do
    cp "$fixture/unit" "$fixture/drift"
    case "$drift" in
    missing) sed -i '/^Volume=live-data/d' "$fixture/drift" ;;
    duplicate) printf 'Volume=other-data:/home/ubuntu/.bitmonero\n' >>"$fixture/drift" ;;
    readonly) sed -i 's|live-data:/home/ubuntu/.bitmonero$|live-data:/home/ubuntu/.bitmonero:ro|' "$fixture/drift" ;;
    publication) printf 'PublishPort=18085:18085\n' >>"$fixture/drift" ;;
    dependency) printf 'Requires=another.service\n' >>"$fixture/drift" ;;
    esac
    if rewrite "$fixture/drift" >/dev/null 2>&1; then
        echo "FAIL: resource rewrite accepted $drift drift" >&2
        exit 1
    fi
done
echo 'selftest-monero-rpc: resource isolation and 5 renderer drift cases passed'
# A failed container/network removal still removes the generated service and scratch.
mkdir "$fixture/scratch"
touch "$fixture/proof.container"
cleanup_source=$(awk '/^cleanup\(\) \{/ { copy=1 } copy { print } copy && /^\}/ { exit }' "$SCRIPT_DIR/monero-quadlet-proof.sh")
if (
    # Variables are consumed by the extracted cleanup function.
    # shellcheck disable=SC2034
    proof_name=fixture-name proof_dir="$fixture/scratch" unit="$fixture/proof.container"
    systemctl() { printf 'systemctl %s\n' "$*" >>"$fixture/cleanup.log"; }
    podman() {
        printf 'podman %s\n' "$*" >>"$fixture/cleanup.log"
        case "$1 $2" in 'container exists' | 'network exists') return 0 ;; *) return 1 ;; esac
    }
    eval "$cleanup_source"
    cleanup
) >/dev/null 2>&1; then
    echo 'FAIL: cleanup hid container/network removal failure' >&2
    exit 1
fi
[ ! -e "$fixture/proof.container" ]
[ ! -e "$fixture/scratch" ]
grep -qxF 'systemctl daemon-reload' "$fixture/cleanup.log"
grep -qxF 'podman network rm fixture-name' "$fixture/cleanup.log"
echo 'selftest-monero-rpc: failed removal still cleans the generated unit and scratch'
# A failed service stop cannot pass even if the container has disappeared.
mkdir "$fixture/scratch"
touch "$fixture/proof.container"
cleanup_source=$(awk '/^cleanup\(\) \{/ { copy=1 } copy { print } copy && /^\}/ { exit }' "$SCRIPT_DIR/monero-quadlet-proof.sh")
if (
    # shellcheck disable=SC2034
    proof_name=fixture-name proof_dir="$fixture/scratch" unit="$fixture/proof.container"
    systemctl() { case "$1" in stop) return 1 ;; is-active) echo active ;; esac }
    podman() { return 1; }
    eval "$cleanup_source"
    cleanup
) >"$fixture/active.log" 2>&1; then
    echo 'FAIL: cleanup hid an active service after failed stop' >&2
    exit 1
fi
grep -qxF 'FAIL: native Quadlet proof service did not stop' "$fixture/active.log"
[ ! -e "$fixture/proof.container" ]
[ ! -e "$fixture/scratch" ]
echo 'selftest-monero-rpc: failed service stop cannot pass with an active unit'
