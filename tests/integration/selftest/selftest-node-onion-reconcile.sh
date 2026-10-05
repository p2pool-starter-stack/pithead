#!/usr/bin/env bash
# Local-node onion provisioning reconciles cached addresses with retained Tor keys before recreate.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RECONCILE_ROOT="$(cd "$HERE/../../.." && pwd)"
# shellcheck source=tests/integration/lib.sh
source "$HERE/../lib.sh"
# shellcheck source=lib/pithead/32-onion-provisioning.sh
source "$RECONCILE_ROOT/lib/pithead/32-onion-provisioning.sh"

echo "== node onion provisioning: retained identity wins over stale cache (#2951) =="
T="$(mktemp -d)"
trap 'rm -rf "$T"' EXIT

onion() {
    printf '%*s.onion' 56 '' | tr ' ' "$1"
}
A="$(onion a)" B="$(onion b)" C="$(onion c)" D="$(onion d)"

probe() { # <id> <monero-mode> <monero-cache> <monero-kept> <tari-mode> <tari-cache> <tari-kept> [read-fail-service]
    (
        local dir="$T/$1" monero_kept="$4" tari_kept="$7" read_fail="${8:-}"
        TOR_DATA_DIR="$dir/tor"
        # shellcheck disable=SC2034 # read by the sourced provisioning function
        MONERO_MODE="$2" MONERO_ONION="$3" TARI_MODE="$5" TARI_ONION="$6"
        mkdir -p "$TOR_DATA_DIR/monero" "$TOR_DATA_DIR/tari"
        printf 'secret-key\n' >"$TOR_DATA_DIR/monero/hs_ed25519_secret_key"
        [ "$monero_kept" = absent ] || printf '%s\n' "$monero_kept" >"$TOR_DATA_DIR/monero/hostname"
        [ "$tari_kept" = absent ] || printf '%s\n' "$tari_kept" >"$TOR_DATA_DIR/tari/hostname"
        : >"$dir/docker" && : >"$dir/asked" && : >"$dir/renders"
        error() {
            printf 'error:%s\n' "$1" >&2
            exit 1
        }
        log() { :; }
        sudo() {
            [ "$1" != -n ] || shift
            "$@"
        }
        cat() {
            [ -z "$read_fail" ] || [[ "$*" != *"/$read_fail/hostname"* ]] || return 1
            command cat "$@"
        }
        compose_up() { printf '%s ' "$*" >>"$dir/docker"; }
        render_env() { printf x >>"$dir/renders"; }
        wait_for_onion() {
            printf '%s,' "$1" >>"$dir/asked"
            case "$1" in monero) printf '%s\n' "$A" ;; tari) printf '%s\n' "$B" ;; esac
        }
        provision_node_onions
        printf '%s|%s|%s|%s|%s|%s' \
            "$(command cat "$dir/docker")" "$(command cat "$dir/asked")" \
            "$MONERO_ONION" "$TARI_ONION" "$(command cat "$dir/renders")" \
            "$(command cat "$TOR_DATA_DIR/monero/hs_ed25519_secret_key")"
    )
}

assert_eq "stale local Monero and Tari caches reconcile from retained hostnames without starting Tor" \
    "$(probe stale local "$A" "$C" local "$B" "$D")" "||$C|$D|x|secret-key"
assert_eq "matching local caches remain a free no-op" \
    "$(probe matching local "$A" "$A" local "$B" "$B")" "||$A|$B||secret-key"
assert_eq "remote nodes ignore retained local hostname state" \
    "$(probe remote remote "$A" invalid remote "$B" invalid)" "||$A|$B||secret-key"
assert_eq "missing local caches retain the fresh Tor publication path" \
    "$(probe missing local placeholder absent local '' absent)" "-d tor |monero,tari,|$A|$B|x|secret-key"

out="$(probe invalid local "$A" invalid remote "$B" absent 2>&1)"
assert_rc "malformed retained hostname refuses reconciliation" "$?" 1
assert_contains "malformed retained hostname reports the affected node" "$out" \
    "Could not safely read the retained Monero Tor hostname"
out="$(probe unreadable local "$A" "$C" remote "$B" absent monero 2>&1)"
assert_rc "unreadable retained hostname refuses reconciliation" "$?" 1
assert_contains "unreadable retained hostname reports the affected node" "$out" \
    "Could not safely read the retained Monero Tor hostname"
out="$(probe absent local "$A" absent remote "$B" absent 2>&1)"
assert_rc "missing retained hostname refuses a cached local identity" "$?" 1
assert_contains "missing retained hostname reports the affected node" "$out" \
    "Could not safely read the retained Monero Tor hostname"

printf 'node onion reconciliation: %s passed, %s failed\n' "$IT_PASS" "$IT_FAIL"
[ "$IT_FAIL" -eq 0 ]
