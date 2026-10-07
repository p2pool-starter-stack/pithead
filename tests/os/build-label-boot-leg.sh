#!/usr/bin/env bash
# Match the first menu's title, before userspace can repair grubenv.
set -euo pipefail
log=${1:?serial log required}
offset=${2:?byte offset required}
version=${3:?version required}
label=${4:-}
media=${5:?media required}
slot=${6:?slot required}
[[ "$offset" =~ ^[0-9]+$ ]] || exit 2
case "$media" in
usb) prefix='USB drive: ' ;;
internal) prefix='Internal disk: ' ;;
*) exit 2 ;;
esac
[ -z "$label" ] || version="$version+$label"
tail -c "+$((offset + 1))" "$log" | grep -F "${prefix}Pithead $version (slot $slot, current)" >/dev/null
