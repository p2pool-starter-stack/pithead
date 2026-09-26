#!/usr/bin/env bash
# derived_state_fingerprint (#2057): a stack directory whose CLI predates control_unit_dir still
# fingerprints, instead of aborting under set -e (job 1152: v1.20.0 has no control_unit_dir).
set -euo pipefail

SELF="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HERE="$SELF/.."
# shellcheck source=tests/integration/lib.sh
source "$HERE/lib.sh"
# shellcheck source=tests/integration/lib/live-gates.sh
source "$HERE/lib/live-gates.sh"

td="$(mktemp -d)"
trap 'rm -rf "$td"' EXIT
IT_MODE=local
IT_REMOTE_DIR="$td"
printf 'x\n' >"$td/.env"
printf 'y\n' >"$td/Caddyfile"
mkdir -p "$td/build"
printf 'z\n' >"$td/build/f"

echo "== a CLI without control_unit_dir still fingerprints, never aborts empty =="
printf '# v1.20.0-shaped: no control_unit_dir\n' >"$td/pithead"
fp1="$(derived_state_fingerprint)"
[ -n "$fp1" ]
[[ "$fp1" =~ ^[0-9a-f]{64}$ ]]

echo "== a CLI that defines control_unit_dir still fingerprints, and a real unit dir changes it =="
printf 'control_unit_dir() { printf %%s "%s"; }\n' "$td" >"$td/pithead"
fp2="$(derived_state_fingerprint)"
[ -n "$fp2" ]
[ "$fp2" != "$fp1" ]

echo "== state that actually changes moves the fingerprint, with or without control_unit_dir =="
printf '# v1.20.0-shaped: no control_unit_dir\n' >"$td/pithead"
printf 'changed\n' >"$td/.env"
fp3="$(derived_state_fingerprint)"
[ "$fp3" != "$fp1" ]

echo "== a stack missing .env fails closed, not vacuously empty =="
rm "$td/.env"
if derived_state_fingerprint >/dev/null 2>&1; then
    echo "expected derived_state_fingerprint to fail without .env" >&2
    exit 1
fi

echo "selftest-derived-state-fingerprint: PASS"
