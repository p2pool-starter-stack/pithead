#!/usr/bin/env bash
# capture_state_snapshots (#2057, job 1190): a failure names which mount and which of the four
# checks it stopped at, in $UPGRADE_SNAPSHOT_REASON, never a full source path.
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

echo "== an empty capture reports no-stateful-mounts, not silent success =="
! capture_state_snapshots "" 2>/dev/null
[ "$UPGRADE_SNAPSHOT_REASON" = no-stateful-mounts ]

echo "== a relative or root source is refused before touching the target =="
! capture_state_snapshots $'svc\tdst\trelative/path\tbind' 2>/dev/null
[ "$UPGRADE_SNAPSHOT_REASON" = not-absolute ]
! capture_state_snapshots $'svc\tdst\t/\tbind' 2>/dev/null
[ "$UPGRADE_SNAPSHOT_REASON" = not-absolute ]

echo "== a missing directory is named by its basename, never its full path =="
missing="$td/does-not-exist"
! capture_state_snapshots "svc"$'\t'"dst"$'\t'"$missing"$'\t'"bind" 2>/dev/null
[ "$UPGRADE_SNAPSHOT_REASON" = "not-a-directory:does-not-exist" ]

echo "== a symlinked source is refused, never followed =="
mkdir -p "$td/real"
ln -s "$td/real" "$td/linked"
! capture_state_snapshots "svc"$'\t'"dst"$'\t'"$td/linked"$'\t'"bind" 2>/dev/null
[ "$UPGRADE_SNAPSHOT_REASON" = "is-a-symlink:linked" ]

echo "== a pre-existing snapshot path is refused, never overwritten =="
mkdir -p "$td/src"
# capture_state_snapshots computes its own nonce from $$ and `date +%s`; shadow `date` as a shell
# function (looked up before $PATH, in this same interpreter) so the test predicts the exact
# snapshot path instead of racing the wall clock.
date() { echo 424242424; }
snap="$td/.pithead-live-src-$$-424242424"
mkdir -p "$snap"
! capture_state_snapshots "svc"$'\t'"dst"$'\t'"$td/src"$'\t'"bind" 2>/dev/null
unset -f date
[ "$UPGRADE_SNAPSHOT_REASON" = "snapshot-path-exists:src" ]
# The failure path's own cleanup already removed $snap (it does on every failure, not knowing
# this one pre-existed rather than being its own partial copy) — nothing left to tidy up here.

echo "== a filesystem that cannot reflink falls back to a full copy instead of refusing =="
mkdir -p "$td/noreflink"
printf 'content\n' >"$td/noreflink/f" # cp -a on an empty dir never attempts a reflink clone at all
capture_state_snapshots "svc"$'\t'"dst"$'\t'"$td/noreflink"$'\t'"bind"
[ -z "$UPGRADE_SNAPSHOT_REASON" ]
[ "$(cat "$td"/.pithead-live-noreflink-*/f)" = content ]

echo "== a copy that genuinely fails names the copy step, not a generic failure =="
mkdir -p "$td/nocopy"
printf 'content\n' >"$td/nocopy/f"
# capture_state_snapshots's copy runs as `sudo -n cp ...`; shadow sudo as an exported function so
# the SAME bash -c snippet rx() launches inherits it (export -f propagates through the environment
# to any child bash, not just this interpreter) and the copy fails deterministically, independent
# of what this sandbox's real sudo/filesystem would actually do.
sudo() { return 1; }
export -f sudo
! capture_state_snapshots "svc"$'\t'"dst"$'\t'"$td/nocopy"$'\t'"bind" 2>/dev/null
unset -f sudo
[ "$UPGRADE_SNAPSHOT_REASON" = "copy-failed:nocopy" ]

echo "== a failure never leaves a stray snapshot directory behind =="
stray="$(find "$td" -maxdepth 1 -name '.pithead-live-nocopy-*' -print)"
[ -z "$stray" ] || {
    echo "expected the failed copy attempt to clean up its own snapshot dir, found: $stray" >&2
    exit 1
}

echo "selftest-capture-state-snapshots: PASS"
