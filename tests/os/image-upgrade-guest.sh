#!/usr/bin/env bash
# Runs inside the disposable KVM guest; inputs were staged by phases/image-upgrade.sh.
set -euo pipefail

INPUT=/run/pithead-image-upgrade
MOUNT=/mnt/pithead-image-upgrade
LOOP=/data/pithead-image-upgrade.xfs
OLD_SHA=296fe6af551b773bae49486e98517ac274b896cd
NEW_SHA="${1:?candidate commit required}"

cleanup() {
    if mountpoint -q "$MOUNT"; then
        [ ! -x "$MOUNT/current/pithead" ] || (cd "$MOUNT/current" && ./pithead down >/dev/null 2>&1) || true
        cd /
        umount "$MOUNT" || umount -l "$MOUNT" || true
    fi
    rm -rf "$INPUT"
    rm -f "$LOOP"
}
trap cleanup EXIT

systemctl stop pithead-firstboot.service
podman rm -f pithead-wizard >/dev/null 2>&1 || true
truncate -s 14G "$LOOP"
mkfs.xfs -f -m reflink=1 "$LOOP" >/dev/null
mkdir -p "$MOUNT"
mount -o loop "$LOOP" "$MOUNT"
xfs_info "$MOUNT" | grep -q 'reflink=1'

cosign verify-blob --key "$INPUT/project.pub" --signature "$INPUT/v1.20.0.sig" \
    --insecure-ignore-tlog=true "$INPUT/v1.20.0.tar.gz" >/dev/null
if cosign verify-blob --key "$INPUT/bundle.pub" --signature "$INPUT/wrong.sig" \
    --insecure-ignore-tlog=true "$INPUT/candidate.tar.gz" >/dev/null 2>&1; then
    echo "candidate bundle accepted a signature from the wrong key" >&2
    exit 1
fi

tar -xzf "$INPUT/v1.20.0.tar.gz" -C "$MOUNT"
mv "$MOUNT/pithead" "$MOUNT/pithead-v1.20.0"
[ "$(tr -d '[:space:]' <"$MOUNT/pithead-v1.20.0/VERSION")" = "1.20.0" ]
[ "$(cat "$MOUNT/pithead-v1.20.0/PITHEAD_COMMIT")" = "$OLD_SHA" ]
ln -s pithead-v1.20.0 "$MOUNT/current"
install -m 0600 "$INPUT/config.json" "$MOUNT/pithead-v1.20.0/config.json"
mkdir "$MOUNT/harness"
tar -xzf "$INPUT/harness.tar.gz" -C "$MOUNT/harness"

(
    cd "$MOUNT/current"
    printf '\n' | env -u PITHEAD_REGISTRY -u PITHEAD_REGISTRY_CA PITHEAD_APPLIANCE=1 \
        ./pithead setup --skip-deps --skip-optimize
)

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
