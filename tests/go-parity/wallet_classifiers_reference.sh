#!/usr/bin/env bash
set -Eeuo pipefail

root=$1
operation=$2
values=$3
export PITHEAD_IMPL="${WALLET_CLASSIFIERS_IMPL:-bash}"
export PITHEAD_CONFIG_FILE="$values"
export NO_COLOR=1
unset PITHEAD_GO_HELPER

# shellcheck source=/dev/null
source "$root/lib/pithead/00-prelude.sh"
# shellcheck source=/dev/null
source "$root/lib/pithead/25-address-types.sh"
# shellcheck source=/dev/null
source "$root/lib/pithead/25a-go-address-types.sh"
if [ "${WALLET_CLASSIFIERS_WITHOUT_HOOK:-0}" = 1 ]; then unset -f _config_address_type_go; fi

python3() {
    if [ "${1:-}" != -c ]; then printf 'legacy\n' >>"$WALLET_CLASSIFIERS_CALLS"; fi
    case "${WALLET_CLASSIFIERS_PYTHON_MODE:-normal}" in
    broken) return 127 ;;
    noisy) printf 'noise\n' ;;
    esac
    local python_rc=0
    "$WALLET_CLASSIFIERS_PYTHON" "$@" || python_rc=$?
    if [ "${WALLET_CLASSIFIERS_PYTHON_MODE:-normal}" = trailing-noise ]; then printf '\n'; fi
    return "$python_rc"
}

if [ "$operation" = gate ]; then
    # shellcheck disable=SC1090
    source <(
        printf '_wallet_classifiers_gate() {\n'
        sed -n '/^    case "$(monero_address_type /,/^    if ! command -v _parse_payout_monero_go /p' \
            "$root/lib/pithead/28-parse-and-validate-config.sh" | sed '$d'
        printf '}\n'
    )
    for field in MONERO_WALLET TARI_WALLET TARI_MODE; do
        IFS= read -r -d '' value
        printf -v "$field" '%s' "$value"
    done <"$values"
else
    IFS= read -r -d '' value <"$values"
fi

if [ "${WALLET_CLASSIFIERS_PYTHON_MODE:-normal}" = missing ]; then
    unset -f python3
    PATH=${WALLET_CLASSIFIERS_EMPTY_PATH:?}
    export PATH
fi

case "$operation" in
monero) monero_address_type "$value" ;;
tari) tari_address_type "$value" ;;
gate)
    _wallet_classifiers_gate
    printf 'accepted\n'
    ;;
*) exit 64 ;;
esac
