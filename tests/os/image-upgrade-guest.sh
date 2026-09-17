#!/usr/bin/env bash
# Runs inside the disposable KVM guest; inputs were staged by phases/image-upgrade.sh.
set -euo pipefail

INPUT=/run/pithead-image-upgrade
MOUNT=/mnt/pithead-image-upgrade
LOOP=/data/pithead-image-upgrade.xfs
OLD_SHA=296fe6af551b773bae49486e98517ac274b896cd
NEW_SHA="${1:?candidate commit required}"
GUEST_STAGE=guest-preflight

record_failure() { # <exit-status>
    local rc="$1"
    case "$GUEST_STAGE" in
    guest-preflight | reflink-volume | bundle-trust | baseline-install | baseline-setup | upgrade-gate | unattributed) ;;
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
    GUEST_STAGE=baseline-setup
    if (record_failure 17); then
        exit 1
    else
        rc=$?
    fi
    [ "$rc" -eq 17 ] && [ "$(cat "$INPUT/guest-stage")" = 'stage=baseline-setup exit=17' ]
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
    rm -f "$LOOP"
}
trap 'record_failure $?' ERR
trap cleanup EXIT

systemctl stop pithead-firstboot.service
podman rm -f pithead-wizard >/dev/null 2>&1 || true
GUEST_STAGE=reflink-volume
truncate -s 14G "$LOOP"
mkfs.xfs -f -m reflink=1 "$LOOP" >/dev/null
mkdir -p "$MOUNT"
mount -o loop "$LOOP" "$MOUNT"
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

GUEST_STAGE=baseline-setup
(
    cd "$MOUNT/current"
    printf '\n' | env -u PITHEAD_REGISTRY -u PITHEAD_REGISTRY_CA PITHEAD_APPLIANCE=1 \
        ./pithead setup --skip-deps --skip-optimize
)

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
