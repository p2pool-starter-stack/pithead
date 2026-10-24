#!/usr/bin/env bash
# Portable privilege-path proof; lan-guard-marker.sh retains the real-root startup fixture.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# An optional slice lets a reviewer run the same assertions against an unfixed writer.
# shellcheck source=lib/pithead/02b-lan-guard.sh
source "${1:-$HERE/../../../lib/pithead/02b-lan-guard.sh}"
fixture=$(mktemp -d "${TMPDIR:-${RUNNER_TEMP:?}}/lan-guard-marker.XXXXXX")
trap 'chmod -R u+w "$fixture"; rm -rf "$fixture"' EXIT
LAN_GUARD_MARKER="$fixture/guard/enforced"
BOOT_ID_FILE="$fixture/boot-id"
printf 'portable-boot\n' >"$BOOT_ID_FILE"
mkdir "$fixture/guard"
chmod 555 "$fixture/guard"
[ ! -w "$fixture/guard" ] || {
    echo 'Requires a non-root test user' >&2
    exit 1
}
# Grant access only during the simulated privileged command. No real sudo is called.
sudo() {
    [ "$1" = -n ] || return 1
    shift
    printf '%s\n' "$1" >>"$fixture/sudo.log"
    [ "${deny_tee:-0}" != 1 ] || [ "$1" != tee ] || return 1
    local rc=0
    command chmod 755 "$fixture/guard"
    command "$@" || rc=$?
    command chmod 555 "$fixture/guard"
    return "$rc"
}
lan_guard_mark
[ "$(cat "$LAN_GUARD_MARKER")" = portable-boot ]
[ "$(LC_ALL=C ls -l "$LAN_GUARD_MARKER" | cut -c 1-10)" = -rw-r--r-- ]
[ ! -w "$fixture/guard" ]
[ "$(cat "$fixture/sudo.log")" = "$(printf 'mktemp\ntee\nchmod\nmv')" ]
# A denied privileged write must fail and clean its sibling temporary file, preserving the old marker.
printf 'next-boot\n' >"$BOOT_ID_FILE"
deny_tee=1
if lan_guard_mark; then
    echo 'Denied privileged write reported success' >&2
    exit 1
fi
[ "$(cat "$LAN_GUARD_MARKER")" = portable-boot ]
[ ! -w "$fixture/guard" ]
shopt -s nullglob
temps=("$LAN_GUARD_MARKER".*)
[ "${#temps[@]}" = 0 ]
echo 'lan-guard-marker-portable: PASS'
