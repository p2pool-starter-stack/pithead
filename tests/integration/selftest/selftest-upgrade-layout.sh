#!/usr/bin/env bash
# The image-upgrade gate's post-upgrade comparisons (#2057, job 158 on a832bc1d): signed pins and
# inspected refs compare by name and digest, and a baseline whose data lives inside its own
# version dir is refused before the stack stops.
set -euo pipefail

SELF="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HERE="$SELF/.."
# shellcheck source=tests/integration/lib.sh
source "$HERE/lib.sh"
# shellcheck source=tests/integration/lib/live-gates.sh
source "$HERE/lib/live-gates.sh"

d1="sha256:$(printf '1%.0s' {1..64})" d2="sha256:$(printf '2%.0s' {1..64})"

echo "== a pinned tag@digest and the engine's bare digest are the same ref =="
pinned="tor reg.test:5000/pithead/pithead-tor:2.0.0@$d1
caddy caddy:2.11.4@$d2
docker-proxy tecnativa/docker-socket-proxy:v0.5.0@$d2"
running="caddy docker.io/library/caddy@$d2
docker-proxy docker.io/tecnativa/docker-socket-proxy@$d2
tor reg.test:5000/pithead/pithead-tor@$d1"
[ "$(canonical_refs "$pinned")" = "$(canonical_refs "$running")" ]

echo "== a different digest, name or registry still differs =="
[ "$(canonical_refs "tor reg.test:5000/pithead/pithead-tor@$d2")" != "$(canonical_refs "tor reg.test:5000/pithead/pithead-tor:2.0.0@$d1")" ]
[ "$(canonical_refs "tor reg.test:5000/pithead/pithead-p2pool@$d1")" != "$(canonical_refs "tor reg.test:5000/pithead/pithead-tor@$d1")" ]
[ "$(canonical_refs "tor other.test/pithead/pithead-tor@$d1")" != "$(canonical_refs "tor reg.test:5000/pithead/pithead-tor@$d1")" ]

echo "== a registry port is never mistaken for a tag =="
[ "$(canonical_refs "tor reg.test:5000/pithead-tor@$d1")" = "tor reg.test:5000/pithead-tor@$d1" ]

td="$(mktemp -d)"
trap 'rm -rf "$td"' EXIT
IT_MODE=local
IT_REMOTE_DIR="$td/pithead-v1.20.0"
mkdir -p "$IT_REMOTE_DIR/data/tor" "$td/data/monero"

echo "== data inside the version dir is named, variable by variable =="
printf 'MONERO_DATA_DIR=%s\nTOR_DATA_DIR=%s\nTARI_DATA_DIR=\n' "$td/data/monero" "$IT_REMOTE_DIR/data/tor" >"$IT_REMOTE_DIR/.env"
[ "$(data_dirs_inside_install "$IT_REMOTE_DIR")" = TOR_DATA_DIR ]

echo "== a path reaching the version dir through a symlink is still inside it =="
ln -s pithead-v1.20.0 "$td/current"
printf 'P2POOL_DATA_DIR=%s\n' "$td/current/data/tor" >"$IT_REMOTE_DIR/.env"
[ "$(data_dirs_inside_install "$IT_REMOTE_DIR")" = P2POOL_DATA_DIR ]

echo "== a shared root beside the version dirs passes, including a sibling-prefix name =="
mkdir -p "$td/pithead-v1.20.0-data"
printf 'MONERO_DATA_DIR=%s\nDASHBOARD_DATA_DIR=%s\n' "$td/data/monero" "$td/pithead-v1.20.0-data" >"$IT_REMOTE_DIR/.env"
[ -z "$(data_dirs_inside_install "$IT_REMOTE_DIR")" ]

echo "== lost durable rows are named by category and count, never by row hash =="
before=$'blocks -\nblocks aaa\nblocks bbb\nhistory ccc\nkv_store-stable ddd\npayouts -'
after=$'blocks -\nblocks aaa\nhistory zzz\nkv_store-stable ddd\npayouts -\nblocks new'
[ "$(telemetry_rows_lost "$before" "$after")" = "blocks:1,history:1" ]
[ -z "$(telemetry_rows_lost "$before" "$before"$'\nextra eee')" ]
! telemetry_rows_lost "$before" "$after" | grep -q 'bbb\|ccc' || exit 1

echo "== a failed exact restore names every check that differed =="
grep -Fq '"differs:$failed; recovery' "$HERE/lib/live-upgrade-support.sh"
! grep -q 'failed=1' <(sed -n '/^restore_upgrade_baseline()/,/^}/p' "$HERE/lib/live-upgrade-support.sh") || exit 1
[ "$(sed -n '/^restore_upgrade_baseline()/,/^}/p' "$HERE/lib/live-upgrade-support.sh" | grep -c 'failed+=" ')" = 22 ]

echo "selftest-upgrade-layout: PASS"
