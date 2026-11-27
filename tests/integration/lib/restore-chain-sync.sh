# shellcheck shell=bash
# Source-side probe is streamed to the restored baseline; it changes no daemon state.
RESTORE_CHAIN_SYNC_PROBE="$(dirname "${BASH_SOURCE[0]}")/restore-chain-sync.py"

verify_chain_sync_proof() {
    local out reason=unavailable deadline=$(($(date +%s) + 600))
    while :; do
        if out="$(on_bench "cd '$RESTORE_DIR' && timeout 25 python3 -" <"$RESTORE_CHAIN_SYNC_PROBE")" &&
            [ "$out" = "Monero authenticated synchronized=true; Tari direct initial_sync_achieved=true" ]; then
            ok "restore proof: $out"
            return 0
        fi
        case "$out" in
        'independent daemon sync not proved: environment' | \
            'independent daemon sync not proved: monero-rpc' | \
            'independent daemon sync not proved: monero-sync' | \
            'independent daemon sync not proved: tari-command' | \
            'independent daemon sync not proved: tari-sync') reason=${out##*: } ;;
        *) reason=unavailable ;;
        esac
        if [ "$(date +%s)" -ge "$deadline" ]; then
            warn "restore proof: independent authenticated Monero and direct Tari sync not proved within 600s (stage: $reason)"
            return 1
        fi
        sleep 10
    done
}
