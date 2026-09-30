#!/usr/bin/env bash
# Pure daemon predicates and bounded restoration poll; no Docker or network access.
set -euo pipefail
echo "== Independent restoration chain sync =="
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
python3 "$HERE/test_restore_chain_sync.py"
# shellcheck source=tests/integration/lib/restore-chain-sync.sh
source "$HERE/../lib/restore-chain-sync.sh"
RESTORE_DIR=/fixture
ok() { :; }
warn() { printf '%s\n' "$*"; }
poll_case() (
    local scenario=$1 now=0
    date() { echo "$now"; }
    sleep() { now=600; }
    on_bench() {
        cat >/dev/null
        case "$scenario" in
        good) echo 'Monero authenticated synchronized=true; Tari direct initial_sync_achieved=true' ;;
        failed)
            echo 'Monero authenticated synchronized=true; Tari direct initial_sync_achieved=true'
            return 1
            ;;
        environment | monero-rpc | monero-sync | tari-command | tari-sync)
            echo "independent daemon sync not proved: $scenario"
            return 1
            ;;
        multiline)
            printf 'independent daemon sync not proved: tari-command\nprivate-endpoint fixture-password\n'
            return 1
            ;;
        private)
            echo 'independent daemon sync not proved: private-endpoint fixture-password'
            return 1
            ;;
        missing) echo 'rpc-ok' ;;
        late) return 1 ;;
        esac
    }
    verify_chain_sync_proof
)
poll_case good
for scenario in failed missing late; do
    if poll_case "$scenario"; then
        echo "unexpected restoration sync PASS: $scenario" >&2
        exit 1
    fi
done
for scenario in environment monero-rpc monero-sync tari-command tari-sync private multiline; do
    if out=$(poll_case "$scenario"); then
        echo 'diagnostic output passed without sync' >&2
        exit 1
    fi
    case "$scenario" in private | multiline) expected=unavailable ;; *) expected=$scenario ;; esac
    [[ "$out" == *"(stage: $expected)" ]] || exit 1
    [[ "$out" != *private-endpoint* && "$out" != *fixture-password* ]] || exit 1
done
# Missing mandatory payload must not become a successful command with no assertions.
if (
    RESTORE_CHAIN_SYNC_PROBE="$HERE/absent-required-probe.py"
    poll_case good
); then
    echo 'missing required restoration probe passed' >&2
    exit 1
fi
echo 'restore-chain-sync self-test: all cases passed'
