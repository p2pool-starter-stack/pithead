#!/usr/bin/env bash
set -Eeuo pipefail

root=$1
target=$2
case "${CADDY_TEST_IFS_MODE:-default}" in
default) ;;
empty) IFS= ;;
colon) IFS=: ;;
*) exit 64 ;;
esac

# shellcheck source=/dev/null
source "$root/tests/go-parity/caddy_reference.sh" "$root" "$target"
