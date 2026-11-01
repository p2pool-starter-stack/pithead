#!/usr/bin/env bash
# shellcheck disable=SC2034
set -Eeuo pipefail

root=$1
block=$2
values=$3
export PITHEAD_IMPL="${TARI_WRITER_IMPL:-bash}"
unset PITHEAD_GO_HELPER
# shellcheck source=/dev/null
source "$root/lib/pithead/33e-go-tari-secret.sh"
# shellcheck source=/dev/null
source "$block"
exec 3<"$values"
IFS= read -r -d '' target <&3
IFS= read -r -d '' APP_UID <&3
IFS= read -r -d '' APP_GID <&3
IFS= read -r -d '' TARI_VIEW_KEY <&3
IFS= read -r -d '' TARI_SPEND_PUBLIC_KEY <&3
IFS= read -r -d '' TARI_WALLET_PASSWORD <&3
IFS= read -r -d '' TARI_PAYOUT_CONFIRM_ENABLED <&3
PITHEAD_ENV_DRYRUN="$PWD/dry-run.env"
error() {
    printf '[ERROR] %s\n' "$1" >&2
    exit 1
}
_secret_event() { printf '%s\n' "$1" >>"$TARI_SECRET_CALLS"; }
case "${TARI_SECRET_SHIM:-}" in
inspect-fail) find() {
    _secret_event find
    return 1
} ;;
ownership-fail | ownership-recover)
    find() {
        _secret_event find
        printf '%s\n' "$1"
    }
    chown() {
        _secret_event chown
        return 1
    }
    sudo() {
        _secret_event sudo
        [ "$TARI_SECRET_SHIM" = ownership-recover ]
    }
    ;;
temp-fail) mktemp() {
    _secret_event mktemp
    return 1
} ;;
rename-fail) mv() {
    _secret_event mv
    return 1
} ;;
esac
if [ "${TARI_SECRET_WITHOUT_HOOK:-0}" = 1 ]; then
    unset -f _render_tari_secret_go
else
    eval "$(declare -f _render_tari_secret_go | sed '1s/_render_tari_secret_go/_secret_native_reference/')"
    _render_tari_secret_go() {
        local status=0
        _secret_native_reference "$@" || status=$?
        printf '%s\n' "$status" >>"$TARI_SECRET_NATIVE"
        return "$status"
    }
fi
_secret_finish() {
    local status=$?
    trap - EXIT
    printf '%s\n' "${tari_secret_ok-unset}" >"$TARI_SECRET_STATE"
    exit "$status"
}
trap _secret_finish EXIT
umask "${TARI_SECRET_UMASK:-022}"
render_secret_case
