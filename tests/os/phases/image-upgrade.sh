# shellcheck shell=bash
: "${OS_RUN_SUITE:?source via the suite runner}"

IMAGE_UPGRADE_HOST_STAGE=""

_image_upgrade_inputs_valid() {
    local host port
    for host in "${REMOTE_MONERO_HOST:-}" "${REMOTE_TARI_HOST:-}"; do
        case "$host" in "" | *:* | *[!A-Za-z0-9._-]*) return 1 ;; esac
    done
    for port in "${REMOTE_MONERO_RPC_PORT:-}" "${REMOTE_MONERO_ZMQ_PORT:-}"; do
        [[ "$port" =~ ^[0-9]+$ ]] && [ "$port" -ge 1 ] && [ "$port" -le 65535 ] || return 1
    done
    [ -n "${PITHEAD_REGISTRY:-}" ]
}

_image_upgrade_prepare_inputs() {
    local stage="$1" cosign_member
    cosign_member="$(tar -tf os/build/pithead-root.tar | grep -E '(^|/)usr/local/bin/cosign$' | head -n1)"
    [ -n "$cosign_member" ] || return 1
    tar -xOf os/build/pithead-root.tar "$cosign_member" >"$stage/cosign" || return 1
    chmod 0700 "$stage/cosign"
    curl -fsSL --retry 3 -o "$stage/v1.20.0.tar.gz" \
        https://github.com/p2pool-starter-stack/pithead/releases/download/v1.20.0/pithead.tar.gz || return 1
    curl -fsSL --retry 3 -o "$stage/v1.20.0.sig" \
        https://github.com/p2pool-starter-stack/pithead/releases/download/v1.20.0/pithead.tar.gz.sig || return 1
    cp cosign.pub "$stage/project.pub" || return 1
    "$stage/cosign" verify-blob --key "$stage/project.pub" --signature "$stage/v1.20.0.sig" \
        --insecure-ignore-tlog=true "$stage/v1.20.0.tar.gz" >/dev/null 2>&1 || return 1
    ok "published v1.20.0 bundle verifies with the project public key"

    COSIGN_PASSWORD='' "$stage/cosign" generate-key-pair --output-key-prefix "$stage/bundle" >/dev/null 2>&1 || return 1
    COSIGN_PASSWORD='' "$stage/cosign" generate-key-pair --output-key-prefix "$stage/wrong" >/dev/null 2>&1 || return 1
    COSIGN_PASSWORD='' PATH="$stage:$PATH" PITHEAD_REGISTRY="$PITHEAD_REGISTRY" \
        tests/os/image-upgrade-bundle.sh "$stage/candidate.tar.gz" "$(git rev-parse HEAD)" \
        "$stage/bundle.key" >/dev/null 2>&1 || return 1
    COSIGN_PASSWORD='' "$stage/cosign" sign-blob --yes --tlog-upload=false --key "$stage/wrong.key" \
        --output-signature "$stage/wrong.sig" "$stage/candidate.tar.gz" >/dev/null 2>&1 || return 1
    if "$stage/cosign" verify-blob --key "$stage/bundle.pub" --signature "$stage/wrong.sig" \
        --insecure-ignore-tlog=true "$stage/candidate.tar.gz" >/dev/null 2>&1; then
        return 1
    fi
    ok "candidate bundle rejects a signature from the wrong key"

    tar -xOf "$stage/v1.20.0.tar.gz" pithead/config.reference.json | jq \
        --arg monero_wallet "$HARNESS_WALLET" --arg tari_wallet "$HARNESS_TARI" \
        --arg monero_host "$REMOTE_MONERO_HOST" --argjson monero_rpc "$REMOTE_MONERO_RPC_PORT" \
        --argjson monero_zmq "$REMOTE_MONERO_ZMQ_PORT" --arg tari_host "$REMOTE_TARI_HOST" '
            .monero.wallet_address = $monero_wallet |
            .monero.mode = "remote" | .monero.remote.host = $monero_host |
            .monero.remote.rpc_port = $monero_rpc | .monero.remote.zmq_port = $monero_zmq |
            .tari.wallet_address = $tari_wallet | .tari.mode = "remote" |
            .tari.remote.host = $tari_host | .p2pool.pool = "mini" |
            .local_miner.enabled = true | .xvb.enabled = false
        ' >"$stage/config.json" || return 1
    chmod 0600 "$stage/config.json"
    tar --no-xattrs -czf "$stage/harness.tar.gz" tests/integration || return 1
}

_image_upgrade_stage_guest() {
    _ssh 'rm -rf /run/pithead-image-upgrade && install -d -m 0700 /run/pithead-image-upgrade' || return 1
    scp -i "$KEY" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -q \
        "$IMAGE_UPGRADE_HOST_STAGE"/{bundle.pub,candidate.tar.gz,candidate.tar.gz.sig,config.json,harness.tar.gz,project.pub,v1.20.0.sig,v1.20.0.tar.gz,wrong.sig} \
        tests/os/image-upgrade-guest.sh "root@$ip:/run/pithead-image-upgrade/" || return 1
    _ssh 'chmod 0700 /run/pithead-image-upgrade/image-upgrade-guest.sh' || return 1
}

_image_upgrade_clear_guest_inputs() {
    _ssh 'rm -rf /run/pithead-image-upgrade'
}

phase_image_upgrade() {
    info "phase: image-upgrade (signed v1.20.0 -> candidate on guest-local reflink XFS)"
    local ip="" rc=0 cleanup_rc=0 head
    _image_upgrade_inputs_valid || {
        bad "image-upgrade requires REMOTE_MONERO_HOST, REMOTE_MONERO_RPC_PORT, REMOTE_MONERO_ZMQ_PORT, REMOTE_TARI_HOST, and PITHEAD_REGISTRY"
        return
    }
    head="$(git rev-parse HEAD)"
    [[ "$head" =~ ^[0-9a-f]{40}$ ]] || {
        bad "candidate commit is not a full 40-hex revision"
        return
    }
    IMAGE_UPGRADE_HOST_STAGE="$(mktemp -d /tmp/pithead-os-image-upgrade.XXXXXX)" || {
        bad "could not create the private image-upgrade staging directory"
        return
    }
    chmod 0700 "$IMAGE_UPGRADE_HOST_STAGE"
    _image_upgrade_prepare_inputs "$IMAGE_UPGRADE_HOST_STAGE" || {
        bad "could not prepare and verify the release-shaped upgrade inputs"
        return
    }
    _vm_boot_disk "$IMAGE" && _wait_ssh 900 || {
        bad "image-upgrade guest never answered test SSH"
        return
    }
    _image_upgrade_stage_guest || {
        _image_upgrade_clear_guest_inputs >/dev/null 2>&1 || true
        bad "could not stage the private upgrade inputs inside the guest"
        return
    }
    _ssh "/run/pithead-image-upgrade/image-upgrade-guest.sh $head" || rc=$?
    _image_upgrade_clear_guest_inputs || cleanup_rc=1
    if _ssh '! mountpoint -q /mnt/pithead-image-upgrade && test ! -e /data/pithead-image-upgrade.xfs && test ! -e /run/pithead-image-upgrade'; then
        ok "guest-local reflink volume and private inputs were torn down"
    else
        bad "guest-local reflink volume teardown did not finish"
    fi
    if [ "$rc" -eq 0 ] && [ "$cleanup_rc" -eq 0 ]; then
        ok "deployed image upgrade and exact rollback passed in the disposable guest"
    else
        bad "deployed image upgrade gate failed (guest runner rc=$rc)"
    fi
}
