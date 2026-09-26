# shellcheck shell=bash
: "${OS_RUN_SUITE:?source via the suite runner}"

IMAGE_UPGRADE_HOST_STAGE=""

source "$(dirname "${BASH_SOURCE[0]}")/../lib/input-failure.sh"
_image_upgrade_input_failure() { image_upgrade_input_failure "$@"; }

_image_upgrade_input_run() { # <sub-step> <redacted-command> <command...>
    local step="$1" display="$2" rc
    shift 2
    "$@" >/dev/null 2>&1 && return 0
    rc=$?
    _image_upgrade_input_failure "$step" "$display" "$rc"
}

# The same reserved-node inputs the stack phase passes on (#2057). The host is a name or an IPv4
# literal; since bench-ci#386 the bench hands over its own name, resolved on this host below.
_image_upgrade_inputs_valid() {
    local host port
    for host in "${PITHEAD_OS_MONERO_NODE_HOST:-}" "${PITHEAD_OS_TARI_NODE_HOST:-}"; do
        case "$host" in "" | *:* | *[!A-Za-z0-9._-]*) return 1 ;; esac
    done
    for port in "${PITHEAD_OS_MONERO_RPC_PORT:-}" "${PITHEAD_OS_MONERO_ZMQ_PORT:-}"; do
        [[ "$port" =~ ^[0-9]+$ ]] && [ "$port" -ge 1 ] && [ "$port" -le 65535 ] || return 1
    done
    [ -n "${PITHEAD_REGISTRY:-}" ]
}

# Job 978 failed at remote-node-reachable: the guest cannot resolve the bench's name the way this
# host does (single label, IPv6-only on the LAN). Resolve it here, once, to its first IPv4
# address and hand the guest only that literal. The failure names the sub-step, never the host.
_image_upgrade_node_v4() { # <sub-step> <name-or-literal>
    local address
    address="$(getent ahostsv4 "$2" 2>/dev/null | awk 'NR == 1 { print $1 }')"
    [[ "$address" =~ ^[0-9]{1,3}(\.[0-9]{1,3}){3}$ ]] || {
        _image_upgrade_input_failure "$1" 'getent ahostsv4 <node-host>' 2
        return 2
    }
    printf '%s\n' "$address"
}

_image_upgrade_prepare_inputs() {
    local stage="$1" cosign_member rootfs_members rc monero_v4 tari_v4
    if rootfs_members="$(tar -tf os/build/pithead-root.tar 2>/dev/null)"; then
        :
    else
        rc=$?
        _image_upgrade_input_failure candidate-bundle 'tar -tf <candidate-rootfs>' "$rc"
        return "$rc"
    fi
    cosign_member="$(grep -E '(^|/)usr/local/bin/cosign$' <<<"$rootfs_members" | head -n1)"
    [ -n "$cosign_member" ] || {
        _image_upgrade_input_failure candidate-bundle 'tar -tf <candidate-rootfs>' 1
        return 1
    }
    tar -xOf os/build/pithead-root.tar "$cosign_member" >"$stage/cosign" 2>/dev/null || {
        rc=$?
        _image_upgrade_input_failure candidate-bundle 'tar -xOf <candidate-rootfs> <cosign>' "$rc"
        return "$rc"
    }
    _image_upgrade_input_run signing 'chmod <cosign>' chmod 0700 "$stage/cosign" || return $?
    _image_upgrade_input_run signing 'curl <published-v1.20.0-bundle>' \
        curl -fsSL --retry 3 -o "$stage/v1.20.0.tar.gz" \
        https://github.com/p2pool-starter-stack/pithead/releases/download/v1.20.0/pithead.tar.gz || return $?
    _image_upgrade_input_run signing 'curl <published-v1.20.0-signature>' \
        curl -fsSL --retry 3 -o "$stage/v1.20.0.sig" \
        https://github.com/p2pool-starter-stack/pithead/releases/download/v1.20.0/pithead.tar.gz.sig || return $?
    _image_upgrade_input_run signing 'cp <project-public-key> <private-stage>' \
        cp cosign.pub "$stage/project.pub" || return $?
    _image_upgrade_input_run signing 'cosign verify-blob <published-v1.20.0-bundle>' \
        "$stage/cosign" verify-blob --key "$stage/project.pub" --signature "$stage/v1.20.0.sig" \
        --insecure-ignore-tlog=true "$stage/v1.20.0.tar.gz" || return $?
    ok "published v1.20.0 bundle verifies with the project public key"
    [ -f "${PITHEAD_REGISTRY_COSIGN_PUB:-}" ] && [ ! -L "$PITHEAD_REGISTRY_COSIGN_PUB" ] || {
        _image_upgrade_input_failure signing 'cp <image-public-key> <private-stage>' 1
        return 1
    }
    _image_upgrade_input_run signing 'cp <image-public-key> <private-stage>' \
        cp "$PITHEAD_REGISTRY_COSIGN_PUB" "$stage/image.pub" || return $?

    _image_upgrade_input_run signing 'cosign generate-key-pair <bundle-key>' \
        env COSIGN_PASSWORD= "$stage/cosign" generate-key-pair --output-key-prefix "$stage/bundle" || return $?
    _image_upgrade_input_run signing 'cosign generate-key-pair <wrong-key>' \
        env COSIGN_PASSWORD= "$stage/cosign" generate-key-pair --output-key-prefix "$stage/wrong" || return $?
    COSIGN_PASSWORD='' PATH="$stage:$PATH" PITHEAD_REGISTRY="$PITHEAD_REGISTRY" \
        PITHEAD_REGISTRY_CA="${PITHEAD_REGISTRY_CA:-}" \
        tests/os/image-upgrade-bundle.sh "$stage/candidate.tar.gz" "$(git rev-parse HEAD)" \
        "$stage/bundle.key" "$stage/image.pub" >/dev/null || {
        rc=$?
        _image_upgrade_input_failure candidate-bundle 'tests/os/image-upgrade-bundle.sh <candidate> <commit> <bundle-key>' "$rc"
        return "$rc"
    }
    _image_upgrade_sign_wrong_key "$stage" || return $?
    if "$stage/cosign" verify-blob --key "$stage/bundle.pub" --signature "$stage/wrong.sig" \
        --insecure-ignore-tlog=true "$stage/candidate.tar.gz" >/dev/null 2>&1; then
        _image_upgrade_input_failure signing \
            'cosign verify-blob <candidate> with <wrong-public-key>' 0 || true
        return 1
    fi
    ok "candidate bundle rejects a signature from the wrong key"

    # Job 698 (#2057): the remote node's own get_info answers 401 unauthenticated — it requires
    # RPC login, and p2pool's --rpc-login was empty, which is why it never got past its own
    # startup no matter how reachable the host/port were. PITHEAD_OS_MONERO_NODE_USERNAME/
    # _PASSWORD are already forwarded through the same `sudo env` as PITHEAD_OS_MONERO_NODE_HOST
    # (bench-preparation.md/operations.md), just never read here; empty (the historical default)
    # still means "no auth", unchanged.
    monero_v4="$(_image_upgrade_node_v4 monero-node-address "$PITHEAD_OS_MONERO_NODE_HOST")" || return $?
    tari_v4="$(_image_upgrade_node_v4 tari-node-address "$PITHEAD_OS_TARI_NODE_HOST")" || return $?
    if (
        umask 077
        printf %s "${PITHEAD_OS_MONERO_NODE_PASSWORD:-}" >"$stage/monero-pass"
    ); then
        :
    else
        rc=$?
        _image_upgrade_input_failure generated-config 'printf <node-password> > <private-file>' "$rc"
        return "$rc"
    fi
    if tar -xOf "$stage/v1.20.0.tar.gz" pithead/config.reference.json 2>/dev/null | jq \
        --arg monero_wallet "$HARNESS_WALLET" --arg tari_wallet "$HARNESS_TARI" \
        --arg monero_host "$monero_v4" --argjson monero_rpc "$PITHEAD_OS_MONERO_RPC_PORT" \
        --argjson monero_zmq "$PITHEAD_OS_MONERO_ZMQ_PORT" --arg tari_host "$tari_v4" \
        --arg monero_user "${PITHEAD_OS_MONERO_NODE_USERNAME:-}" \
        --rawfile monero_pass "$stage/monero-pass" '
            .monero.wallet_address = $monero_wallet |
            .monero.mode = "remote" | .monero.remote.host = $monero_host |
            .monero.remote.rpc_port = $monero_rpc | .monero.remote.zmq_port = $monero_zmq |
            (if $monero_user != "" then .monero.node_username = $monero_user else . end) |
            (if $monero_pass != "" then .monero.node_password = $monero_pass else . end) |
            .tari.wallet_address = $tari_wallet | .tari.mode = "remote" |
            .tari.remote.host = $tari_host | .p2pool.pool = "mini" |
            .local_miner.enabled = true | .xvb.enabled = false
        ' >"$stage/config.json" 2>/dev/null; then
        :
    else
        rc=$?
        _image_upgrade_input_failure generated-config \
            'tar -xOf <baseline> pithead/config.reference.json | jq <config-transform>' "$rc"
        return "$rc"
    fi
    _image_upgrade_input_run generated-config 'chmod <generated-config>' \
        chmod 0600 "$stage/config.json" || return $?
    # The harness reads one file outside its own tree by relative path: hugepage-probe.sh's
    # REDUCED_PAGES pin in os/overlay/pithead-hugepages (#2685). Without it the guest's
    # harness reported "got []" (job 1229).
    _image_upgrade_input_run candidate-bundle 'tar --no-xattrs -czf <harness> tests/integration os/overlay/pithead-hugepages' \
        tar --no-xattrs -czf "$stage/harness.tar.gz" tests/integration os/overlay/pithead-hugepages || return $?
}

_image_upgrade_sign_wrong_key() { # <private stage>
    local stage="$1"
    _image_upgrade_input_run signing 'cosign sign-blob <candidate> with <wrong-key>' \
        env COSIGN_PASSWORD= "$stage/cosign" sign-blob --yes --use-signing-config=false --new-bundle-format=false \
        --tlog-upload=false \
        --key "$stage/wrong.key" --output-signature "$stage/wrong.sig" "$stage/candidate.tar.gz"
}

_image_upgrade_stage_guest() {
    _ssh 'rm -rf /run/pithead-image-upgrade && install -d -m 0700 /run/pithead-image-upgrade' || return 1
    scp -i "$KEY" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -q \
        "$IMAGE_UPGRADE_HOST_STAGE"/{bundle.pub,candidate.tar.gz,candidate.tar.gz.sig,config.json,harness.tar.gz,image.pub,project.pub,v1.20.0.sig,v1.20.0.tar.gz,wrong.sig} \
        tests/os/image-upgrade-guest.sh "root@$ip:/run/pithead-image-upgrade/" || return 1
    _ssh 'chmod 0700 /run/pithead-image-upgrade/image-upgrade-guest.sh' || return 1
}

_image_upgrade_clear_guest_inputs() {
    _ssh 'rm -rf /run/pithead-image-upgrade'
}

_image_upgrade_read_guest_failure() {
    local marker guest_stage exit_status
    marker="$(_ssh 'cat /run/pithead-image-upgrade/guest-stage' 2>/dev/null)" || return 1
    guest_stage="${marker#stage=}"
    guest_stage="${guest_stage%% exit=*}"
    exit_status="${marker##* exit=}"
    case "$guest_stage" in
    guest-preflight | remote-node-reachable | reflink-file | reflink-format | reflink-mountpoint | reflink-mount-loop | reflink-verify | bundle-trust | baseline-install | baseline-compat | baseline-setup | local-miner-tree | local-miner-role | local-miner-render | local-miner-rigforge | local-miner-unit | miner-share | upgrade-gate | unattributed) ;;
    *) return 1 ;;
    esac
    [[ "$exit_status" =~ ^[0-9]+$ ]] && [ "$marker" = "stage=$guest_stage exit=$exit_status" ] || return 1
    printf '%s\n' "$marker"
}

# The built-in miner's measured time to the state the gate demands (#2057). Payload is two
# integers the guest wrote: the seconds it took, and a 4-bit mask of exactly the booleans the
# gate itself reads (monero synced, tari synced, workers, hashes). Anything else is refused, so
# no raw state, secret or topology can reach the log through this path.
_image_upgrade_read_miner_readiness() {
    local marker seconds ready
    marker="$(_ssh 'cat /run/pithead-image-upgrade/miner-readiness' 2>/dev/null)" || return 1
    seconds="${marker#seconds=}"
    seconds="${seconds%% ready=*}"
    ready="${marker##* ready=}"
    [[ "$seconds" =~ ^[0-9]+$ ]] && [[ "$ready" =~ ^([0-9]|1[0-5])$ ]] || return 1
    [ "$marker" = "seconds=$seconds ready=$ready" ] || return 1
    printf '%s %s\n' "$seconds" "$ready"
}

phase_image_upgrade() {
    info "phase: image-upgrade (signed v1.20.0 -> candidate on guest-local reflink XFS)"
    local ip="" rc=0 cleanup_rc=0 head guest_failure="" miner_readiness=""
    _image_upgrade_inputs_valid || {
        bad "image-upgrade requires PITHEAD_OS_MONERO_NODE_HOST, PITHEAD_OS_MONERO_RPC_PORT, PITHEAD_OS_MONERO_ZMQ_PORT, PITHEAD_OS_TARI_NODE_HOST, and PITHEAD_REGISTRY"
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
    _ssh "bash /run/pithead-image-upgrade/image-upgrade-guest.sh $head" || {
        rc=$?
        guest_failure="$(_image_upgrade_read_guest_failure || true)"
    }
    miner_readiness="$(_image_upgrade_read_miner_readiness || true)"
    _image_upgrade_clear_guest_inputs || cleanup_rc=1
    if [ -n "$miner_readiness" ]; then
        info "built-in miner reached ${miner_readiness%% *}s with gate-predicate mask ${miner_readiness##* }/15"
    fi
    if _ssh '! mountpoint -q /data/pithead-image-upgrade-mount && test ! -e /data/pithead-image-upgrade-mount && test ! -e /data/pithead-image-upgrade.xfs && test ! -e /run/pithead-image-upgrade'; then
        ok "guest-local reflink volume and private inputs were torn down"
    else
        bad "guest-local reflink volume teardown did not finish"
    fi
    if [ "$rc" -eq 0 ] && [ "$cleanup_rc" -eq 0 ]; then
        ok "deployed image upgrade and exact rollback passed in the disposable guest"
    else
        bad "deployed image upgrade gate failed (${guest_failure:-stage=unattributed exit=$rc})"
    fi
}
