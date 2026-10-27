#!/usr/bin/env bash
# Runs inside the disposable KVM guest; inputs were staged by phases/image-upgrade.sh.
set -euo pipefail

INPUT=/run/pithead-image-upgrade
MOUNT=/data/pithead-image-upgrade-mount
LOOP=/data/pithead-image-upgrade.xfs
OLD_SHA=c59e5ad6fc7c1fe82eb7558a2f962c18c1266299
MINER_SHARE_BUDGET=1800
NEW_SHA="${1:?candidate commit required}"
GUEST_STAGE=guest-preflight
# The remote-node probe that is running, so a failure names it (#2057). Never a host or port.
GUEST_PRIMITIVE=""
SERIAL_CONSOLE=/dev/ttyS0

# Job 978 failed at remote-node-reachable with the guest journal never captured: each stage's
# verdict goes to the serial console the harness always keeps, and to the harness log.
console() { # <line>
    printf 'image-upgrade guest: %s\n' "$1"
    { printf 'image-upgrade guest: %s\n' "$1" >"$SERIAL_CONSOLE"; } 2>/dev/null || true
}

stage() { # <next-stage>
    console "stage=$GUEST_STAGE passed"
    GUEST_STAGE="$1"
}

record_failure() {
    local rc="$1"
    case "$GUEST_STAGE" in
    guest-preflight | remote-node-reachable | reflink-file | reflink-format | reflink-mountpoint | reflink-mount-loop | reflink-verify | bundle-trust | baseline-install | baseline-setup | local-miner-tree | local-miner-role | local-miner-render | local-miner-rigforge | local-miner-unit | miner-share | upgrade-gate | unattributed) ;;
    *) GUEST_STAGE=unattributed ;;
    esac
    printf 'stage=%s exit=%d\n' "$GUEST_STAGE" "$rc" >"$INPUT/guest-stage"
    console "stage=$GUEST_STAGE failed${GUEST_PRIMITIVE:+ primitive=$GUEST_PRIMITIVE} exit=$rc"
    exit "$rc"
}

verify_bundle_trust() {
    cosign verify-blob --key "$INPUT/project.pub" --signature "$INPUT/v2.0.0.sig" \
        --insecure-ignore-tlog=true "$INPUT/v2.0.0.tar.gz" >/dev/null
    if cosign verify-blob --key "$INPUT/bundle.pub" --signature "$INPUT/wrong.sig" \
        --insecure-ignore-tlog=true "$INPUT/candidate.tar.gz" >/dev/null 2>&1; then
        record_failure 1
    fi
}

install_baseline() {
    tar -xzf "$INPUT/v2.0.0.tar.gz" -C "$MOUNT" || return $?
    mv "$MOUNT/pithead" "$MOUNT/pithead-v2.0.0-baseline" || return $?
    [ "$(tr -d '[:space:]' <"$MOUNT/pithead-v2.0.0-baseline/VERSION")" = "2.0.0" ] || return 1
    ln -s pithead-v2.0.0-baseline "$MOUNT/current"
}

setup_baseline() {
    (
        cd "$MOUNT/current" || exit $?
        printf '\n' | env -u PITHEAD_REGISTRY -u PITHEAD_REGISTRY_CA PITHEAD_APPLIANCE=0 \
            ./pithead setup --skip-deps --skip-optimize
    )
}

if [ "$NEW_SHA" = --self-test ]; then
    INPUT="$(mktemp -d)"
    SERIAL_CONSOLE=/dev/null
    trap 'rm -rf "$INPUT"' EXIT
    for GUEST_STAGE in remote-node-reachable reflink-file reflink-format reflink-mountpoint reflink-mount-loop reflink-verify local-miner-tree local-miner-role local-miner-render local-miner-rigforge local-miner-unit miner-share baseline-setup; do
        if (record_failure 17 >/dev/null); then
            exit 1
        else
            rc=$?
        fi
        [ "$rc" -eq 17 ] && [ "$(cat "$INPUT/guest-stage")" = "stage=$GUEST_STAGE exit=17" ] || exit 1
    done
    GUEST_STAGE=remote-node-reachable GUEST_PRIMITIVE="tcp zmq"
    [ "$( (record_failure 17) || true)" = 'image-upgrade guest: stage=remote-node-reachable failed primitive=tcp zmq exit=17' ] || exit 1
    GUEST_PRIMITIVE=""
    [ "$(stage reflink-file)" = 'image-upgrade guest: stage=remote-node-reachable passed' ] || exit 1
    cosign() { :; }
    GUEST_STAGE=bundle-trust
    if (verify_bundle_trust >/dev/null); then
        exit 1
    else
        rc=$?
    fi
    [ "$rc" -eq 1 ] && [ "$(cat "$INPUT/guest-stage")" = 'stage=bundle-trust exit=1' ]
    MOUNT="$INPUT/install"
    mkdir -p "$INPUT/fixture/pithead" "$MOUNT"
    printf '2.0.0\n' >"$INPUT/fixture/pithead/VERSION"
    printf 'signed-compose-fixture\n' >"$INPUT/fixture/pithead/docker-compose.yml"
    tar -czf "$INPUT/v2.0.0.tar.gz" -C "$INPUT/fixture" pithead
    install_baseline
    [ "$(readlink "$MOUNT/current")" = pithead-v2.0.0-baseline ]
    [ ! -e "$MOUNT/pithead-v2.0.0" ]
    cmp "$INPUT/fixture/pithead/docker-compose.yml" "$MOUNT/current/docker-compose.yml"
    printf '%s\n' '#!/usr/bin/env bash' \
        '[ "$*" = "setup --skip-deps --skip-optimize" ] || exit 2' \
        '[ "$PITHEAD_APPLIANCE" = 0 ] || exit 3' \
        '[ -z "${PITHEAD_REGISTRY+x}${PITHEAD_REGISTRY_CA+x}" ] || exit 4' \
        'exit "${SETUP_EXIT:-0}"' >"$MOUNT/current/pithead"
    chmod +x "$MOUNT/current/pithead"
    PITHEAD_APPLIANCE=1 PITHEAD_REGISTRY=registry.example PITHEAD_REGISTRY_CA=unused setup_baseline
    setup_rc=0
    SETUP_EXIT=17 setup_baseline || setup_rc=$?
    [ "$setup_rc" -eq 17 ]
    rm -rf "$MOUNT"
    mkdir "$MOUNT"
    printf '1.20.0\n' >"$INPUT/fixture/pithead/VERSION"
    tar -czf "$INPUT/v2.0.0.tar.gz" -C "$INPUT/fixture" pithead
    if install_baseline; then
        exit 1
    fi
    [ ! -e "$MOUNT/current" ]
    echo "image-upgrade-guest self-test: PASS"
    exit
fi

cleanup() {
    if mountpoint -q "$MOUNT"; then
        [ ! -x "$MOUNT/current/pithead" ] || (cd "$MOUNT/current" && ./pithead down >/dev/null 2>&1) || true
        cd /
        umount "$MOUNT" || umount -l "$MOUNT" || true
    fi
    rmdir "$MOUNT" 2>/dev/null || true
    rm -f "$LOOP"
}
trap 'record_failure $?' ERR
trap cleanup EXIT

# Jobs 639/642/657/672/688 all reached `miner-share` and stuck at the same unmet predicates
# (monero sync, hashes); job 672 found p2pool never healthy the whole run (its healthcheck is a
# bare TCP connect to its OWN stratum port — nothing about the remote node) and its network-stats
# file never created, i.e. p2pool never got past its own startup. Job 688 proved a bare TCP
# connect to the RPC port alone is not the gap: it passed, the run proceeded normally for the
# full budget, and p2pool's stats dir was STILL empty — p2pool needs the ZMQ port too (real-time
# block notifications), never checked before. Check both, and the RPC port's actual `get_info`
# response, not just the handshake, before the ~15 minutes of image pulls and setup. A boolean is
# neither raw state nor topology; the host/ports themselves are never printed (#2057).
stage remote-node-reachable
_remote_monero_host="$(jq -r '.monero.remote.host' "$INPUT/config.json")"
_remote_monero_rpc="$(jq -r '.monero.remote.rpc_port' "$INPUT/config.json")"
_remote_monero_zmq="$(jq -r '.monero.remote.zmq_port' "$INPUT/config.json")"
GUEST_PRIMITIVE="tcp zmq"
timeout 5 bash -c "echo >/dev/tcp/$_remote_monero_host/$_remote_monero_zmq" 2>/dev/null
GUEST_PRIMITIVE="rpc http"
# Any HTTP status (even a 401 the remote's own auth policy returns) proves the RPC service is
# there and answering; only curl's own exit code (connection refused/timed out) means unreachable.
_remote_get_info="$(curl -sS --max-time 5 -w '\n%{http_code}' "http://$_remote_monero_host:$_remote_monero_rpc/get_info" 2>/dev/null)"
_remote_rpc_status="${_remote_get_info##*$'\n'}"
[ -n "$_remote_rpc_status" ]
GUEST_PRIMITIVE=""
# get_info's own status/nettype/height/target_height are public monerod facts (its `status` field,
# network type and chain heights), not this box's state or topology — worth knowing whether p2pool
# and the remote node even agree on which network they're both on.
echo "[diag] get_info http=$_remote_rpc_status body=$(head -c 400 <<<"${_remote_get_info%$'\n'*}" | jq -c '{status,nettype,height,target_height}' 2>/dev/null || echo unparseable) (#2057)"
unset _remote_monero_host _remote_monero_rpc _remote_monero_zmq _remote_get_info _remote_rpc_status

systemctl stop pithead-firstboot.service
podman rm -f pithead-wizard >/dev/null 2>&1 || true
stage reflink-file
truncate -s 14G "$LOOP"
stage reflink-format
mkfs.xfs -f -m reflink=1 "$LOOP" >/dev/null
stage reflink-mountpoint
mkdir -p "$MOUNT"
stage reflink-mount-loop
mount -o loop "$LOOP" "$MOUNT"
stage reflink-verify
xfs_info "$MOUNT" | grep -q 'reflink=1'

stage bundle-trust
verify_bundle_trust

stage baseline-install
install_baseline
(umask 077 && jq --arg root "$MOUNT/data" '
    .monero.data_dir = ($root + "/monero") | .tari.data_dir = ($root + "/tari") |
    .p2pool.data_dir = ($root + "/p2pool") | .tor.data_dir = ($root + "/tor") |
    .dashboard.data_dir = ($root + "/dashboard")
' "$INPUT/config.json" >"$MOUNT/config.shared-data.json")
install -m 0600 "$MOUNT/config.shared-data.json" "$MOUNT/current/config.json"
rm -f "$MOUNT/config.shared-data.json"
mkdir "$MOUNT/harness"
tar -xzf "$INPUT/harness.tar.gz" -C "$MOUNT/harness"

stage baseline-setup
setup_baseline

stage local-miner-tree
[ -x /data/rigforge/rigforge.sh ] && [ -d /data/rigforge ]
stage local-miner-role
[ "$(cat "$MOUNT/current/machine-role" 2>/dev/null || echo pithead)" != rig ]

local_miner_rc=0
(
    cd "$MOUNT/current"
    PITHEAD_APPLIANCE=1 PITHEAD_CONFIG_FILE="$MOUNT/current/config.json" \
        PITHEAD_ENV_FILE="$MOUNT/current/.env" PITHEAD_MACHINE_ROLE_FILE="$MOUNT/current/machine-role" \
        /opt/pithead/pithead local-miner
) || local_miner_rc=$?
if [ "$local_miner_rc" -ne 0 ]; then
    if [ -f /data/rigforge/config.json ]; then
        GUEST_STAGE=local-miner-rigforge
    else
        GUEST_STAGE=local-miner-render
    fi
    record_failure "$local_miner_rc"
fi

stage local-miner-unit
systemctl is-active --quiet xmrig.service

# Wait for the miner to reach the state the gate demands, and record how long it took. The budget
# is a measurement ceiling, not a guess: the run that sets it reports the real figure, and only
# the four booleans the gate itself reads are ever written out — no raw state, no topology.
stage miner-share
miner_start=$SECONDS
miner_ready=0
while :; do
    miner_state="$(curl -fsS --max-time 10 http://127.0.0.1:8000/api/state 2>/dev/null || true)"
    miner_ready=0
    [ "$(jq -r '.sync.monero.state // ""' <<<"$miner_state" 2>/dev/null)" = "done" ] && miner_ready=$((miner_ready + 1))
    [ "$(jq -r '.sync.tari.state // ""' <<<"$miner_state" 2>/dev/null)" = "done" ] && miner_ready=$((miner_ready + 2))
    [ "$(jq -r '.proxy_workers // 0' <<<"$miner_state" 2>/dev/null)" -ge 1 ] 2>/dev/null && miner_ready=$((miner_ready + 4))
    [ "$(jq -r '.stratum.total_hashes // 0' <<<"$miner_state" 2>/dev/null)" -gt 0 ] 2>/dev/null && miner_ready=$((miner_ready + 8))
    printf 'seconds=%d ready=%d\n' "$((SECONDS - miner_start))" "$miner_ready" >"$INPUT/miner-readiness"
    [ "$miner_ready" -eq 15 ] && break
    if [ "$((SECONDS - miner_start))" -ge "$MINER_SHARE_BUDGET" ]; then
        # Jobs 639/642 both stuck at mask 6/15 (monero sync + hashes unmet, tari + workers met)
        # for the whole budget, not slowly progressing. Job 657's first attempt at this
        # diagnostic reported "unreadable" with no further detail; print every step (the
        # resolved dir, the file's existence, its content) so a second unreadable result says
        # WHY. p2pool's network-stats file holds only public chain height/difficulty — data_service.py
        # forces monero is_syncing=true whenever its height reads 0, per its own documented caveat.
        p2pool_dir="$(grep -m1 '^P2POOL_DATA_DIR=' "$MOUNT/current/.env" 2>/dev/null | cut -d= -f2-)"
        echo "[diag] P2POOL_DATA_DIR=${p2pool_dir:-<unset>} (#2057)"
        echo "[diag] $(ls -la "${p2pool_dir:-/nonexistent}/stats/network/" 2>&1)"
        echo "[diag] network-stats content: $(cat "${p2pool_dir:-/nonexistent}/stats/network/stats" 2>&1)"
        record_failure 1
    fi
    sleep 10
done

stage upgrade-gate
# The harness writes its warnings, its "did NOT run" list (#1365) and its failure names to
# stderr, and the phase's _ssh sends a guest's stderr to its private SSH_ERR file: merge them, or
# a passing gate's log cannot say which legs it skipped (job 1258 counted 3, named none).
monero_host="$(jq -r '.monero.remote.host' "$INPUT/config.json")"
monero_rpc="$(jq -r '.monero.remote.rpc_port' "$INPUT/config.json")"
monero_zmq="$(jq -r '.monero.remote.zmq_port' "$INPUT/config.json")"
tari_host="$(jq -r '.tari.remote.host' "$INPUT/config.json")"
PITHEAD_APPLIANCE=0 env -u PITHEAD_REGISTRY -u PITHEAD_REGISTRY_CA \
    "$MOUNT/harness/tests/integration/run.sh" --local --dir "$MOUNT/current" --workers 1 \
    --remote-monero-host "$monero_host" --remote-monero-rpc-port "$monero_rpc" \
    --remote-monero-zmq-port "$monero_zmq" --remote-tari-host "$tari_host" \
    --scenario remote-main-secure-tari --safety-backup \
    --image-upgrade "$OLD_SHA" "$NEW_SHA" \
    --candidate-bundle "$INPUT/candidate.tar.gz" "$INPUT/candidate.tar.gz.sig" "$INPUT/bundle.pub" \
    --candidate-image-key "$INPUT/image.pub" --out "$MOUNT/results" 2>&1
console "stage=$GUEST_STAGE passed"
