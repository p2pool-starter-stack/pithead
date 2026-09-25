#!/usr/bin/env bash
# Runs inside the disposable KVM guest; inputs were staged by phases/image-upgrade.sh.
set -euo pipefail

INPUT=/run/pithead-image-upgrade
MOUNT=/data/pithead-image-upgrade-mount
LOOP=/data/pithead-image-upgrade.xfs
OLD_SHA=296fe6af551b773bae49486e98517ac274b896cd
# Measurement ceiling for the built-in miner's first accepted share (#2057). The deployed run
# reports the figure it actually took; this bound exists so a miner that never mines fails the
# gate instead of hanging it. Job 639, the first run to ever get this far (local-miner render was
# broken before it), reported gate-predicate mask 6/15 (tari synced + workers, not monero synced
# or hashes) still short at the old 1200s ceiling — raised to 1800s, the figure tests/os/lib/core.sh's
# own SSH_TIMEOUT comment already assumed for "the 1800s local-miner wait" before this constant
# ever matched it.
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

record_failure() { # <exit-status>
    local rc="$1"
    case "$GUEST_STAGE" in
    guest-preflight | remote-node-reachable | reflink-file | reflink-format | reflink-mountpoint | reflink-mount-loop | reflink-verify | bundle-trust | baseline-install | baseline-compat | baseline-setup | local-miner-tree | local-miner-role | local-miner-render | local-miner-rigforge | local-miner-unit | miner-share | upgrade-gate | unattributed) ;;
    *) GUEST_STAGE=unattributed ;;
    esac
    printf 'stage=%s exit=%d\n' "$GUEST_STAGE" "$rc" >"$INPUT/guest-stage"
    console "stage=$GUEST_STAGE failed${GUEST_PRIMITIVE:+ primitive=$GUEST_PRIMITIVE} exit=$rc"
    exit "$rc"
}

verify_bundle_trust() {
    cosign verify-blob --key "$INPUT/project.pub" --signature "$INPUT/v1.20.0.sig" \
        --insecure-ignore-tlog=true "$INPUT/v1.20.0.tar.gz" >/dev/null
    if cosign verify-blob --key "$INPUT/bundle.pub" --signature "$INPUT/wrong.sig" \
        --insecure-ignore-tlog=true "$INPUT/candidate.tar.gz" >/dev/null 2>&1; then
        record_failure 1
    fi
}

if [ "$NEW_SHA" = --self-test ]; then
    INPUT="$(mktemp -d)"
    SERIAL_CONSOLE=/dev/null
    trap 'rm -rf "$INPUT"' EXIT
    for GUEST_STAGE in remote-node-reachable reflink-file reflink-format reflink-mountpoint reflink-mount-loop reflink-verify baseline-compat local-miner-tree local-miner-role local-miner-render local-miner-rigforge local-miner-unit miner-share baseline-setup; do
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
tar -xzf "$INPUT/v1.20.0.tar.gz" -C "$MOUNT"
mv "$MOUNT/pithead" "$MOUNT/pithead-v1.20.0"
[ "$(tr -d '[:space:]' <"$MOUNT/pithead-v1.20.0/VERSION")" = "1.20.0" ]
ln -s pithead-v1.20.0 "$MOUNT/current"
# Data on a shared root beside the version dirs, never inside one: `pithead upgrade` only deploys a
# fresh version dir when every data dir resolves outside the running one, and the gate stages
# exactly that layout. With v1.20.0's `auto` defaults the data sat in pithead-v1.20.0/data and the
# candidate came up beside it on empty dirs (job 158). Same reflink volume, so snapshots stay CoW.
(umask 077 && jq --arg root "$MOUNT/data" '
    .monero.data_dir = ($root + "/monero") | .tari.data_dir = ($root + "/tari") |
    .p2pool.data_dir = ($root + "/p2pool") | .tor.data_dir = ($root + "/tor") |
    .dashboard.data_dir = ($root + "/dashboard")
' "$INPUT/config.json" >"$MOUNT/config.shared-data.json")
install -m 0600 "$MOUNT/config.shared-data.json" "$MOUNT/pithead-v1.20.0/config.json"
rm -f "$MOUNT/config.shared-data.json"
mkdir "$MOUNT/harness"
tar -xzf "$INPUT/harness.tar.gz" -C "$MOUNT/harness"

# v1.20.0's docker-compose.yml sets tmpfs `uid=1000,gid=1000` on wallet-rpc, tari-wallet and
# xmrig-proxy; Docker accepts it but this appliance's Podman-compatible API rejects it as an
# unknown mount option (job 480). Later releases fixed this the same way current develop's
# docker-compose.yml already does: drop uid=/gid= and, where the entry had no explicit mode=
# of its own (xmrig-proxy's /home/ubuntu, unlike the two /tmp entries), add `mode=1777` so the
# tmpfs stays world-writable without the rejected owner pin — job 542 proved dropping uid=/gid=
# alone is not enough: xmrig-proxy's entrypoint could no longer write its own tmpfs and crashed
# immediately (`container died`, main process exit status 1, seconds after `baseline-setup`
# otherwise succeeded). The signed bundle stays byte-identical on disk; only this guest-local
# extracted copy is patched. `make_bundle` digest-pins first-party image refs into
# docker-compose.yml at release-build time, so the packaged file is never byte-identical to the
# git-tracked source — checksum only the exact tmpfs lines being touched (untouched by digest
# pinning), not the whole file, so an unexpected bundle fails closed instead of being silently
# rewritten.
stage baseline-compat
compose_file="$MOUNT/pithead-v1.20.0/docker-compose.yml"
[ "$(grep -F ',uid=1000,gid=1000' "$compose_file" | sha256sum | cut -d' ' -f1)" = cffbad16a895b738a4a21025961a8980df516c29c9d03842f0323b2932980405 ]
sed -i -e 's/,mode=1777,uid=1000,gid=1000/,mode=1777/g' -e 's/,uid=1000,gid=1000/,mode=1777/g' "$compose_file"

stage baseline-setup
(
    cd "$MOUNT/current"
    printf '\n' | env -u PITHEAD_REGISTRY -u PITHEAD_REGISTRY_CA PITHEAD_APPLIANCE=1 \
        ./pithead setup --skip-deps --skip-optimize
)

# The gate's success signal is real mining: `run.sh --image-upgrade` refuses --no-mining-asserts,
# so it needs >=1 proxy worker and a positive stratum hash count from a stack that was set up
# seconds ago. The appliance ships its own miner (the baked RigForge tree and prebuilt XMRig), and
# `local-miner` is its one supported invocation — it renders the miner's config at 127.0.0.1's
# stratum port and starts the same xmrig.service unit a provisioned coordinator runs. The baseline
# is v1.20.0, which predates that subcommand, so the APPLIANCE's own CLI is invoked against the
# baseline stack directory rather than the bundle's.
# Split into named checkpoints (job 537: the CLI call alone gave no sub-stage) so the next
# deployed run identifies which primitive failed without widening the phase-private payload —
# the same pattern jobs 478-480 used to isolate the reflink mount boundary.
stage local-miner-tree
[ -x /data/rigforge/rigforge.sh ] && [ -d /data/rigforge ]
# `render_local_miner_config` returns 0 WITHOUT writing its config on exactly two branches: a
# missing RigForge tree (ruled out above) and a machine_role of `rig`. Job 553/632 (jobs 553 and
# 632, before this fix) reported local-miner-render even with both ruled out: 00-prelude.sh's
# `cd "$SCRIPT_DIR"` runs on EVERY invocation of /opt/pithead/pithead, unconditionally — so `cd
# "$MOUNT/current"` below never put the CLI's $PWD there, and machine_role() (which reads
# $PWD/machine-role, with no override before #2057) actually read /opt/pithead/machine-role, the
# appliance's OWN marker, not the baseline's. Assert the baseline's role directly so the stage
# name still distinguishes it from a genuine render failure.
stage local-miner-role
[ "$(cat "$MOUNT/current/machine-role" 2>/dev/null || echo pithead)" != rig ]

# `pithead local-miner` renders RigForge's own config.json (a side effect that always happens
# first, win or lose) THEN runs `rigforge.sh setup`. Job 547 got past the tmpfs fix cleanly —
# every container including xmrig-proxy started and stayed healthy — but this call still failed,
# with nothing in the guest journal to say where inside it. Whether config.json exists afterward
# tells render from rigforge.sh apart without capturing any command output: the appliance's own
# CLI is pithead's to fix, RigForge's own `setup` is a companion repo's.
#
# PITHEAD_CONFIG_FILE/PITHEAD_ENV_FILE/PITHEAD_MACHINE_ROLE_FILE, not `cd`: the CLI's own prelude
# `cd`s to its SCRIPT_DIR (/opt/pithead) before reading anything, on every invocation, so pointing
# it at the baseline directory needs the explicit overrides — the same ones the control runner's
# staged-config preview already relies on for the same reason.
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
    --candidate-image-key "$INPUT/image.pub" --out "$MOUNT/results"
console "stage=$GUEST_STAGE passed"
