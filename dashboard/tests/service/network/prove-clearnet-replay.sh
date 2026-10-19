#!/usr/bin/env bash
# Retain source, Linux/ext4 identity and each replay verdict in the GitHub dashboard job.
set -euo pipefail

[ "$(uname -s)" = Linux ] || {
    echo 'Marker replay proof requires Linux.' >&2
    exit 1
}
proof_parent="${RUNNER_TEMP:-${TMPDIR:?Set TMPDIR or RUNNER_TEMP for the replay proof}}"
proof_dir=$(mktemp -d "$proof_parent/clearnet-replay.XXXXXXXX")
trap 'rm -rf "$proof_dir"' EXIT
proof_fs=$(findmnt -n -o FSTYPE -T "$proof_dir")
printf 'Replay proof operating system: Linux\nReplay proof filesystem: %s\n' "$proof_fs"
[ "$proof_fs" = ext4 ] || {
    echo 'Marker replay proof requires an ext4 test directory.' >&2
    exit 1
}
proof_head="${PROOF_HEAD_SHA:-$(git rev-parse HEAD)}"
[[ "$proof_head" =~ ^[0-9a-f]{40}$ ]] || {
    echo 'Marker replay proof requires a full source SHA.' >&2
    exit 1
}
git merge-base --is-ancestor "$proof_head" HEAD
printf 'Replay proof source head: %s\nReplay proof checkout: %s\n' "$proof_head" "$(git rev-parse HEAD)"
uv run --locked --project dashboard --extra test python -m pytest \
    dashboard/tests/service/network/test_clearnet_sync.py::test_replayed_marker_text_does_not_reuse_host_proof \
    --basetemp "$proof_dir/pytest" -vv --maxfail=1
