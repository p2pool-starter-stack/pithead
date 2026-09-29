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

# Query the pinned wallet through the dashboard's existing gRPC client. Never print the address.
_tari_wallet_snapshot() {
    _ssh "podman exec dashboard python -c 'import hashlib, grpc; from mining_dashboard.client.tari.generated import types_pb2, wallet_pb2, wallet_pb2_grpc; channel=grpc.insecure_channel(\"127.0.0.1:18143\"); wallet=wallet_pb2_grpc.WalletStub(channel); version=wallet.GetVersion(wallet_pb2.GetVersionRequest(), timeout=10).version; address=wallet.GetCompleteAddress(types_pb2.Empty(), timeout=10).one_sided_address_base58; state=wallet.GetState(wallet_pb2.GetStateRequest(), timeout=10); print(version, hashlib.sha256(address.encode()).hexdigest(), state.scanned_height, state.balance.available_balance)'" 2>/dev/null | tr -d '\r'
}

tari_wallet_image_is_pinned() { # <image-name> <image-digest> <pinned-ref>
    [ "$2" = "${3##*@}" ] || { [ -z "$2" ] && [ "$1" = "$3" ]; }
}

# 0: readable and clean; 1: integrity error; 2: logs unavailable.
tari_wallet_integrity_log_status() {
    local log grep_rc
    log=$(_ssh "podman logs --tail 200 tari-wallet" 2>&1) || return 2
    [ -n "$log" ] || return 2
    printf '%s\n' "$log" | grep -Eiq '(database|sqlite).*(error|corrupt|malformed|integrity)|integrity.*(failed|error)'
    grep_rc=${PIPESTATUS[1]}
    case "$grep_rc" in 0) return 1 ;; 1) return 0 ;; *) return 2 ;; esac
}

# #2657: the console wallet must not be PID 1 (a zombie PID 1 cannot be signalled), and a stop must
# complete: rc 0 and the container down within the timeout plus a margin. How fast the wallet itself
# shuts down on SIGTERM is the wallet's business, so the exit code is reported, not judged.
tari_wallet_pid1_is_init() { case "$1" in podman-init | catatonit | docker-init) return 0 ;; *) return 1 ;; esac }
tari_wallet_stop_ok() { # <stop-rc> <elapsed-s> <running>
    [ "$1" -eq 0 ] && [ "$2" -lt 25 ] && [ "$3" = false ]
}

phase_provision_tari_wallet() { # <phase-rc>
    local unexercised=bad deadline state restarts health owner argv node pid1 t0 stop_rc stop_s exit_code running dispositions before after version identity height balance after_version after_identity after_height after_balance image_name image_digest expected_image db_before db_after log_status
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
    pid1=$(_ssh "podman exec tari-wallet cat /proc/1/comm" 2>/dev/null | tr -d '\r\n')
    if tari_wallet_pid1_is_init "$pid1"; then
        ok "Tari wallet: PID 1 is podman's init ($pid1), not the wallet (#2657)"
    else
        bad "Tari wallet: PID 1 is '${pid1:-unknown}', not an init (#2657)"
    fi
    dispositions=$(_ssh "podman exec tari-wallet sh -c 'for s in /proc/[0-9]*/status; do grep -q \"^Name:.*minotari_consol\" \"\$s\" && { printf \"%s \" \"\$s\"; grep -E \"^(SigIgn|SigCgt|SigBlk):\" \"\$s\"; }; done'" 2>/dev/null | tr -d '\r' | tr '\n' ' ')
    if [ -n "$dispositions" ]; then info "Tari wallet: signal dispositions (#2899): $dispositions"; else bad "Tari wallet: could not read the wallet process's signal dispositions (#2899)"; fi
    expected_image='ghcr.io/tari-project/minotari_console_wallet:v6.0.1-pre.0-mainnet@sha256:6f1f7d8990d304466f70a0379dcef4825c29b785c10d7fc7dff4d89163ed1b9d'
    read -r image_name image_digest <<<"$(_ssh "podman inspect tari-wallet --format '{{.ImageName}} {{.ImageDigest}}'" 2>/dev/null | tr -d '\r\n')"
    if tari_wallet_image_is_pinned "$image_name" "$image_digest" "$expected_image"; then
        ok "Tari wallet: running the pinned v6.0.1-pre.0 image"
    else
        bad "Tari wallet: running image differs from the pinned v6.0.1-pre.0 image"
    fi
    before=$(_tari_wallet_snapshot)
    read -r version identity height balance <<<"$before"
    if [ -n "$identity" ] && [[ "$version" = *6.0.1-pre.0* ]] && [[ "$height" =~ ^[0-9]+$ ]] && [[ "$balance" =~ ^[0-9]+$ ]]; then
        ok "Tari wallet: pinned wallet answers address and state RPCs before stop"
    else
        bad "Tari wallet: pinned wallet did not answer address and state RPCs before stop"
    fi
    db_before=$(_ssh "podman exec tari-wallet find /var/tari/wallet -name console_wallet.db -type f -exec stat -c %i {} \;" 2>/dev/null | tr -d '\r\n')
    if [[ "$db_before" =~ ^[0-9]+$ ]]; then ok "Tari wallet: persisted SQLite database exists before stop"; else bad "Tari wallet: persisted SQLite database was not found before stop"; fi
    # Exercise the configured default timeout, including a possible forced exit.
    t0=$(date +%s)
    _ssh "podman stop tari-wallet" >/dev/null 2>&1
    stop_rc=$?
    stop_s=$(($(date +%s) - t0))
    exit_code=$(_ssh "podman inspect tari-wallet --format '{{.State.ExitCode}}'" 2>/dev/null | tr -d '\r\n')
    running=$(_ssh "podman inspect tari-wallet --format '{{.State.Running}}'" 2>/dev/null | tr -d '\r\n')
    if tari_wallet_stop_ok "$stop_rc" "$stop_s" "$running"; then
        ok "Tari wallet: podman stop completed in ${stop_s}s with the container down (#2657)"
    else
        bad "Tari wallet: podman stop took ${stop_s}s (rc $stop_rc) and the container is running='${running:-unknown}' (#2657)"
    fi
    info "Tari wallet: exit code after the stop was '${exit_code:-unknown}' (137 means the wallet outlasted the timeout after SIGTERM)"
    _ssh "podman start tari-wallet" >/dev/null 2>&1 || bad "Tari wallet: the wallet did not start again after the stop (#2657)"
    deadline=$(($(date +%s) + 120))
    health=""
    while [ "$(date +%s)" -lt "$deadline" ]; do
        health=$(_ssh "podman inspect tari-wallet --format '{{.State.Health.Status}}'" 2>/dev/null | tr -d '\r\n')
        [ "$health" = healthy ] && break
        sleep 5
    done
    if [ "$health" = healthy ]; then ok "Tari wallet: the stopped wallet restarted healthy (#2899)"; else bad "Tari wallet: the stopped wallet did not restart healthy (#2899)"; fi
    after=$(_tari_wallet_snapshot)
    read -r after_version after_identity after_height after_balance <<<"$after"
    if [ -n "$identity" ] && [ "$after_version" = "$version" ] && [ "$after_identity" = "$identity" ] && [ "$after_balance" = "$balance" ] && [[ "$height" =~ ^[0-9]+$ ]] && [[ "$after_height" =~ ^[0-9]+$ ]] && [ "$after_height" -ge "$height" ]; then
        ok "Tari wallet: the restarted wallet preserved its public identity and reported state (#2899)"
    else
        bad "Tari wallet: the restarted wallet's identity or reported state changed or its RPC failed (#2899)"
    fi
    db_after=$(_ssh "podman exec tari-wallet find /var/tari/wallet -name console_wallet.db -type f -exec stat -c %i {} \;" 2>/dev/null | tr -d '\r\n')
    if [ -n "$db_before" ] && [ "$db_after" = "$db_before" ]; then ok "Tari wallet: the same persisted SQLite database reopened after restart (#2899)"; else bad "Tari wallet: the persisted SQLite database changed or is missing after restart (#2899)"; fi
    tari_wallet_integrity_log_status
    log_status=$?
    case "$log_status" in
    0) ok "Tari wallet: no database-integrity error reported after restart (#2899)" ;;
    1) bad "Tari wallet: database-integrity error reported after restart (#2899)" ;;
    *) bad "Tari wallet: could not read the wallet log after restart (#2899)" ;;
    esac
    approval_restore_pending || bad "Tari wallet cleanup (restoring the original config) failed"
}
_tari_wallet_self_test() {
    local f=0
    tari_wallet_pid1_is_init podman-init && tari_wallet_pid1_is_init catatonit || f=$((f + 1))
    tari_wallet_pid1_is_init minotari_console && f=$((f + 1))
    tari_wallet_pid1_is_init '' && f=$((f + 1))
    tari_wallet_stop_ok 0 2 false || f=$((f + 1))
    tari_wallet_stop_ok 0 11 false || f=$((f + 1))
    tari_wallet_stop_ok 0 25 false && f=$((f + 1))
    tari_wallet_stop_ok 0 2 true && f=$((f + 1))
    tari_wallet_stop_ok 1 2 false && f=$((f + 1))
    tari_wallet_stop_ok 0 2 '' && f=$((f + 1))
    tari_wallet_image_is_pinned wrong sha256:good repo/wallet@sha256:good || f=$((f + 1))
    tari_wallet_image_is_pinned repo/wallet@sha256:good '' repo/wallet@sha256:good || f=$((f + 1))
    tari_wallet_image_is_pinned repo/wallet@sha256:good sha256:wrong repo/wallet@sha256:good && f=$((f + 1))
    tari_wallet_image_is_pinned wrong '' repo/wallet@sha256:good && f=$((f + 1))
    (
        _ssh() { return 255; }
        tari_wallet_integrity_log_status
    )
    [ "$?" -eq 2 ] || f=$((f + 1))
    (
        _ssh() { printf 'wallet opened\n'; }
        tari_wallet_integrity_log_status
    ) || f=$((f + 1))
    (
        _ssh() { printf 'SQLite database corrupt\n'; }
        tari_wallet_integrity_log_status
    )
    [ "$?" -eq 1 ] || f=$((f + 1))
    [ "$f" -eq 0 ] || {
        printf 'appliance-tari-wallet-leg self-test: %s failed\n' "$f" >&2
        return 1
    }
    printf 'appliance-tari-wallet-leg self-test passed\n'
}
if [ "${BASH_SOURCE[0]}" = "$0" ] && [ "${1:-}" = --self-test ]; then
    set -uo pipefail
    _tari_wallet_self_test
fi
