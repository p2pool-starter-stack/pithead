#!/usr/bin/env bash
# Runs inside the disposable KVM guest; inputs were staged by phases/image-upgrade.sh.
set -euo pipefail

INPUT=/run/pithead-image-upgrade
MOUNT=/data/pithead-image-upgrade-mount
LOOP=/data/pithead-image-upgrade.xfs
OLD_SHA=296fe6af551b773bae49486e98517ac274b896cd
# Measurement ceiling for the built-in miner's first accepted share (#2057). The deployed run
# reports the figure it actually took; this bound exists so a miner that never mines fails the
# gate instead of hanging it.
MINER_SHARE_BUDGET=1200
NEW_SHA="${1:?candidate commit required}"
GUEST_STAGE=guest-preflight

record_failure() { # <exit-status>
    local rc="$1"
    case "$GUEST_STAGE" in
    guest-preflight | reflink-file | reflink-format | reflink-mountpoint | reflink-mount-loop | reflink-verify | bundle-trust | baseline-install | baseline-compat | baseline-setup | local-miner-tree | local-miner-setup | local-miner-unit | miner-share | upgrade-gate | unattributed) ;;
    *) GUEST_STAGE=unattributed ;;
    esac
    printf 'stage=%s exit=%d\n' "$GUEST_STAGE" "$rc" >"$INPUT/guest-stage"
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
    trap 'rm -rf "$INPUT"' EXIT
    for GUEST_STAGE in reflink-file reflink-format reflink-mountpoint reflink-mount-loop reflink-verify baseline-compat local-miner-tree local-miner-setup local-miner-unit miner-share baseline-setup; do
        if (record_failure 17); then
            exit 1
        else
            rc=$?
        fi
        [ "$rc" -eq 17 ] && [ "$(cat "$INPUT/guest-stage")" = "stage=$GUEST_STAGE exit=17" ] || exit 1
    done
    sed -n '/^GUEST_STAGE=reflink-mountpoint$/,/^GUEST_STAGE=reflink-mount-loop$/p' "${BASH_SOURCE[0]}" |
        grep -Fx 'mkdir -p "$MOUNT"' >/dev/null || exit 1
    grep -Fx 'MOUNT=/data/pithead-image-upgrade-mount' "${BASH_SOURCE[0]}" >/dev/null || exit 1
    sed -n '/^cleanup()/,/^}/p' "${BASH_SOURCE[0]}" |
        grep -Fx '    rmdir "$MOUNT" 2>/dev/null || true' >/dev/null || exit 1
    sed -n '/^GUEST_STAGE=reflink-mount-loop$/,/^GUEST_STAGE=reflink-verify$/p' "${BASH_SOURCE[0]}" |
        grep -Fx 'mount -o loop "$LOOP" "$MOUNT"' >/dev/null || exit 1
    cosign() { :; }
    GUEST_STAGE=bundle-trust
    if (verify_bundle_trust); then
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

systemctl stop pithead-firstboot.service
podman rm -f pithead-wizard >/dev/null 2>&1 || true
GUEST_STAGE=reflink-file
truncate -s 14G "$LOOP"
GUEST_STAGE=reflink-format
mkfs.xfs -f -m reflink=1 "$LOOP" >/dev/null
GUEST_STAGE=reflink-mountpoint
mkdir -p "$MOUNT"
GUEST_STAGE=reflink-mount-loop
mount -o loop "$LOOP" "$MOUNT"
GUEST_STAGE=reflink-verify
xfs_info "$MOUNT" | grep -q 'reflink=1'

GUEST_STAGE=bundle-trust
verify_bundle_trust

GUEST_STAGE=baseline-install
tar -xzf "$INPUT/v1.20.0.tar.gz" -C "$MOUNT"
mv "$MOUNT/pithead" "$MOUNT/pithead-v1.20.0"
[ "$(tr -d '[:space:]' <"$MOUNT/pithead-v1.20.0/VERSION")" = "1.20.0" ]
ln -s pithead-v1.20.0 "$MOUNT/current"
install -m 0600 "$INPUT/config.json" "$MOUNT/pithead-v1.20.0/config.json"
mkdir "$MOUNT/harness"
tar -xzf "$INPUT/harness.tar.gz" -C "$MOUNT/harness"

# v1.20.0's docker-compose.yml sets tmpfs `uid=1000,gid=1000` on wallet-rpc, tari-wallet and
# xmrig-proxy; Docker accepts it but this appliance's Podman-compatible API rejects it as an
# unknown mount option (job 480). Later releases dropped the option outright. The signed bundle
# stays byte-identical on disk; only this guest-local extracted copy is patched. `make_bundle`
# digest-pins first-party image refs into docker-compose.yml at release-build time, so the
# packaged file is never byte-identical to the git-tracked source — checksum only the exact
# tmpfs lines being touched (untouched by digest pinning), not the whole file, so an unexpected
# bundle fails closed instead of being silently rewritten.
GUEST_STAGE=baseline-compat
compose_file="$MOUNT/pithead-v1.20.0/docker-compose.yml"
[ "$(grep -F ',uid=1000,gid=1000' "$compose_file" | sha256sum | cut -d' ' -f1)" = cffbad16a895b738a4a21025961a8980df516c29c9d03842f0323b2932980405 ]
sed -i 's/,uid=1000,gid=1000//g' "$compose_file"

GUEST_STAGE=baseline-setup
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
GUEST_STAGE=local-miner-tree
[ -x /data/rigforge/rigforge.sh ]
GUEST_STAGE=local-miner-setup
(
    cd "$MOUNT/current"
    PITHEAD_APPLIANCE=1 /opt/pithead/pithead local-miner
)
GUEST_STAGE=local-miner-unit
systemctl is-active --quiet xmrig.service

# Wait for the miner to reach the state the gate demands, and record how long it took. The budget
# is a measurement ceiling, not a guess: the run that sets it reports the real figure, and only
# the four booleans the gate itself reads are ever written out — no raw state, no topology.
GUEST_STAGE=miner-share
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
    [ "$((SECONDS - miner_start))" -lt "$MINER_SHARE_BUDGET" ] || record_failure 1
    sleep 10
done

GUEST_STAGE=upgrade-gate
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
    --candidate-image-key "$INPUT/project.pub" --out "$MOUNT/results"
