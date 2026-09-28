#!/usr/bin/env bash
# The view-only Tari payout wallet under the appliance's quadlets (#462/#2731). Sourced by
# tests/os/run.sh.
#
# The e2e channel proves the wallet on Docker; this is its only Podman coverage. The wallet volume
# must be writable by the image's uid-1000 user or the wallet crash-loops creating its config dir,
# which is how #462 shipped. The leg sets a view key and spend key with a host-side apply (the
# dashboard refuses those keys by design) and checks that the wallet stays up, reports healthy,
# owns its volume, wrote its own config into it and names only the local node. A scratch guest has no synced Tari
# chain, so finding payouts is the e2e row's job, not this one. The keys are a valid scalar and the
# Ristretto basepoint: they parse, and they belong to no real wallet. The config is restored after.
TARI_WALLET_TEST_VIEW_KEY=0100000000000000000000000000000000000000000000000000000000000000
TARI_WALLET_TEST_SPEND_KEY=e2f2ae0a6abc4e71a884a961c500515f58e30b6aa582dd8db6a65945e08d2d76

# Prints "<running> <restart-count>" for the tari-wallet container, or nothing.
_tari_wallet_state() {
    _ssh "podman inspect tari-wallet --format '{{.State.Running}} {{.RestartCount}}'" 2>/dev/null | tr -d '\r'
}

phase_provision_tari_wallet() { # <phase-rc>
    local unexercised=bad deadline state restarts health owner argv node
    [ "${1:-0}" -eq 0 ] || unexercised=info
    info "phase: the view-only Tari payout wallet under podman quadlets (#462/#2731)"
    if ! SSH_TIMEOUT="${SSH_PROBE_TIMEOUT:-20}" _ssh true 2>/dev/null; then
        "$unexercised" "guest is unreachable — the Tari payout wallet was NOT exercised (#2731)"
        return 0
    fi
    _control_requests_drained || {
        "$unexercised" "Tari wallet: the control spool never drained — a host-side apply here would kill a request in flight"
        return 0
    }
    approval_capture_restore_snapshot || {
        "$unexercised" "Tari wallet: could not snapshot the guest's config.json"
        return 0
    }
    if ! _ssh "set -eu
cd /data/pithead
jq -c '.tari.mode = \"local\" | .tari.view_key = \"$TARI_WALLET_TEST_VIEW_KEY\" | .tari.spend_public_key = \"$TARI_WALLET_TEST_SPEND_KEY\" | .tari.payout_scan_birthday = \"1425\"' config.json >config.json.tari-wallet-test
mv config.json.tari-wallet-test config.json
./pithead apply -y" >/dev/null 2>&1; then
        bad "Tari wallet: ./pithead apply -y did not accept a view key and spend key"
        approval_restore_pending || bad "Tari wallet: cleanup after a failed apply also failed"
        return 0
    fi
    deadline=$(($(date +%s) + 300))
    state=""
    while [ "$(date +%s)" -lt "$deadline" ]; do
        state=$(_tari_wallet_state)
        [ "${state%% *}" = true ] && break
        sleep 10
    done
    if [ "${state%% *}" != true ]; then
        bad "Tari wallet: the tari-wallet container never ran (${state:-absent})"
        # The wallet's own words, which the guest journal does not carry.
        _ssh "podman logs --tail 15 tari-wallet 2>&1" 2>/dev/null | tr -d '\r' | sed 's/^/     | /'
    else
        # One wallet start, then 60 s: a wallet that cannot write its volume exits within seconds.
        restarts="${state##* }"
        sleep 60
        state=$(_tari_wallet_state)
        if [ "$state" = "true $restarts" ]; then
            ok "Tari wallet: tari-wallet stays running with no restart for 60 s"
        else
            bad "Tari wallet: tari-wallet did not stay up (was 'true $restarts', now '${state:-absent}')"
        fi
    fi
    deadline=$(($(date +%s) + 120))
    health=""
    while [ "$(date +%s)" -lt "$deadline" ]; do
        health=$(_ssh "podman inspect tari-wallet --format '{{.State.Health.Status}}'" 2>/dev/null | tr -d '\r\n')
        [ "$health" = healthy ] && break
        sleep 10
    done
    if [ "$health" = healthy ]; then
        ok "Tari wallet: the wallet reports healthy under its Quadlet health command"
    else
        bad "Tari wallet: the wallet health status is '${health:-unavailable}', not healthy"
    fi
    # Read from inside the container: the mount root it sees is the volume root, whatever the engine
    # named the volume (job 1512's by-name lookup found none on this channel).
    owner=$(_ssh "podman exec tari-wallet stat -c %u /var/tari/wallet" 2>/dev/null | tr -d '\r\n')
    if [ "$owner" = 1000 ]; then
        ok "Tari wallet: the wallet volume root is owned by the image's uid 1000"
    else
        bad "Tari wallet: the wallet volume root is owned by '${owner:-unknown}', not uid 1000"
    fi
    if _ssh "podman exec tari-wallet test -f /var/tari/wallet/mainnet/config/wallet/log4rs.yml" 2>/dev/null; then
        ok "Tari wallet: the wallet wrote its own config into /var/tari/wallet"
    else
        bad "Tari wallet: no wallet config under /var/tari/wallet — the volume is not writable"
    fi
    node="http://$(_ssh "sed -n 's/^TARI_GRPC_ADDRESS=//p' /data/pithead/.env" 2>/dev/null | tr -d '\r\n' | cut -d: -f1):9000"
    # Every process's argv, not PID 1's: the container runs under an init (#2657), so PID 1 is the init.
    argv=$(_ssh "podman exec tari-wallet sh -c 'cat /proc/[0-9]*/cmdline'" 2>/dev/null | tr '\0' ' ')
    case "$argv" in
    *"wallet.http_server_url=$node "*"wallet.fallback_http_server_url=$node "*) ok "Tari wallet: both scan URLs name the local node ($node)" ;;
    *) bad "Tari wallet: the scan URLs do not both name the local node $node" ;;
    esac
    approval_restore_pending || bad "Tari wallet cleanup (restoring the original config) failed"
}
