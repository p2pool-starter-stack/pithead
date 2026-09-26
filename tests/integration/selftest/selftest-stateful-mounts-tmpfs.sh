#!/usr/bin/env bash
# stateful_mounts excludes tmpfs (#2057, job 1181): xmrig-proxy's /home/ubuntu is RW and shares
# its destination with p2pool's real bind mount, but a tmpfs has no host Source to snapshot —
# capture_state_snapshots requires an absolute Source for every row, so an included tmpfs row
# failed "quiesced writable state captured in private CoW snapshots" for a mount that was never
# live state. Docker is unavailable in this worktree (this Mac runs no Docker), so this proves the
# filter's semantics against fixture `docker inspect` JSON via jq directly, and guards the live
# function's source for the one exclusion clause that makes it correct.
set -euo pipefail

SELF="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HERE="$SELF/.."

echo "== the live filter excludes Type==tmpfs, never just RW+Destination =="
grep -Fq '.RW == true and .Type != "tmpfs" and' "$HERE/lib/live-upgrade-support.sh"

echo "== a tmpfs sharing a bind mount's destination is dropped, the bind mount is kept =="
fixture='[{"Mounts":[
  {"RW":true,"Type":"bind","Destination":"/home/ubuntu","Source":"/data/pithead-v1.20.0/data/p2pool","Name":null},
  {"RW":true,"Type":"tmpfs","Destination":"/home/ubuntu","Source":"","Name":null},
  {"RW":true,"Type":"bind","Destination":"/var/lib/tor","Source":"/data/pithead-v1.20.0/data/tor","Name":null},
  {"RW":false,"Type":"bind","Destination":"/data","Source":"/data/pithead-v1.20.0/data/ro","Name":null}
]}]'
# The same select() clause stateful_mounts() runs (tests/integration/lib/live-upgrade-support.sh),
# against a service name "$s" the way the real snippet supplies it.
out="$(jq -r --arg s p2pool '.[0].Mounts[] | select(.RW == true and .Type != "tmpfs" and (.Destination | IN("/var/lib/tor","/home/ubuntu/.bitmonero","/home/ubuntu/wallets","/var/tari/node","/home/ubuntu/wallet","/home/ubuntu","/data","/clearnet-state","/control/requests","/var/log/caddy"))) | [$s,.Destination,.Source,.Type] | @tsv' <<<"$fixture")"
[ "$(printf '%s\n' "$out" | wc -l)" = 2 ]
printf '%s\n' "$out" | grep -Fq $'p2pool\t/home/ubuntu\t/data/pithead-v1.20.0/data/p2pool\tbind'
printf '%s\n' "$out" | grep -Fq $'p2pool\t/var/lib/tor\t/data/pithead-v1.20.0/data/tor\tbind'
! printf '%s\n' "$out" | grep -q tmpfs || exit 1

echo "selftest-stateful-mounts-tmpfs: PASS"
