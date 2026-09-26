#!/usr/bin/env bash
# capture_state_snapshots (#2057, job 1190): a failure names which mount and which of the four
# checks it stopped at, in $UPGRADE_SNAPSHOT_REASON, never a full source path; a data-dir bind
# mount must reflink or be refused, and only a named volume may be fully copied.
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

echo "== a data-dir bind mount on a filesystem that cannot reflink is refused, never fully copied =="
mkdir -p "$td/noreflink"
printf 'content\n' >"$td/noreflink/f" # cp -a on an empty dir never attempts a reflink clone at all
! capture_state_snapshots "svc"$'\t'"dst"$'\t'"$td/noreflink"$'\t'"bind" 2>/dev/null
[ "$UPGRADE_SNAPSHOT_REASON" = "reflink-copy-failed:noreflink" ]
[ -z "$(find "$td" -maxdepth 1 -name '.pithead-live-noreflink-*' -print)" ]

echo "== only a named volume falls back to a full copy, and the restore copies it back the same way =="
mkdir -p "$td/vol/_data"
printf 'wallet\n' >"$td/vol/_data/f"
capture_state_snapshots "wallet-rpc"$'\t'"/home/ubuntu/wallets"$'\t'"$td/vol/_data"$'\t'"volume"
[ -z "$UPGRADE_SNAPSHOT_REASON" ]
[ "$(cat "$td"/vol/.pithead-live-_data-*/f)" = wallet ]
[ "$(state_reflink_mode "$td/vol/_data")" = auto ]
[ "$(state_reflink_mode "$td/noreflink")" = always ]
cleanup_state_snapshots

echo "== a nested source is snapshotted once, through its parent, whatever the locale =="
mkdir -p "$td/nest/p2pool/a"
printf 'x\n' >"$td/nest/p2pool/a/f"
LC_ALL=en_US.UTF-8 capture_state_snapshots "c"$'\t'"d"$'\t'"$td/nest/p2pool/a"$'\t'"volume"$'\n'"p"$'\t'"d"$'\t'"$td/nest/p2pool"$'\t'"volume" 2>/dev/null
[ "$(printf '%s\n' "$UPGRADE_STATE_SNAPSHOTS" | cut -f1)" = "$td/nest/p2pool" ]
cleanup_state_snapshots

echo "== a copy that genuinely fails names the copy step, not a generic failure =="
mkdir -p "$td/nocopy"
printf 'content\n' >"$td/nocopy/f"
# capture_state_snapshots's copy runs as `sudo -n cp ...`; shadow sudo as an exported function so
# the SAME bash -c snippet rx() launches inherits it (export -f propagates through the environment
# to any child bash, not just this interpreter) and the copy fails deterministically, independent
# of what this sandbox's real sudo/filesystem would actually do.
sudo() { return 1; }
export -f sudo
! capture_state_snapshots "svc"$'\t'"dst"$'\t'"$td/nocopy"$'\t'"volume" 2>/dev/null
unset -f sudo
[ "$UPGRADE_SNAPSHOT_REASON" = "copy-failed:nocopy" ]

echo "== a failure never leaves a stray snapshot directory behind =="
stray="$(find "$td" -maxdepth 1 -name '.pithead-live-nocopy-*' -print)"
[ -z "$stray" ] || {
    echo "expected the failed copy attempt to clean up its own snapshot dir, found: $stray" >&2
    exit 1
}

echo "selftest-capture-state-snapshots: PASS"
