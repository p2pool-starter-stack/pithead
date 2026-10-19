#!/usr/bin/env bash
set -euo pipefail
OS_RUN_SUITE=1 SERIAL=$(mktemp) PASS=0 FAIL=0 KEEP=1
trap 'rm -f "$SERIAL"' EXIT
# shellcheck source=tests/os/lib/core.sh
source "$(dirname "$0")/lib/core.sh"
trap 'rm -f "$SERIAL"' EXIT
printf 'pithead[123]: [pithead] Setup closed: the saved settings are kept\r\n' >"$SERIAL"
head -c 1048576 /dev/zero | tr '\0' x >>"$SERIAL"
serial_has 'pithead\[[0-9]+\]: \[pithead\] Setup closed: the saved settings are kept'
if serial_has 'absent from serial'; then exit 1; fi
grep -Fq "serial_has 'pithead" "$(dirname "$0")/setup-again-leg.sh"
grep -Fq 'if serial_has "$new_wallet"; then' "$(dirname "$0")/phases/media.sh"
