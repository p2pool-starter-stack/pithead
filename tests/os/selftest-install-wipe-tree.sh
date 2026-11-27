#!/usr/bin/env bash
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
# shellcheck source=/dev/null
source <(sed '$d' "$here/../../os/installer/pithead-install")

fail() {
    echo "Install wipe=data tree: FAIL: $*" >&2
    exit 1
}
shape() { ls -ldn "$1" | awk '{print $1, $3, $4}'; }
blk=$(find /dev -maxdepth 1 -type b 2>/dev/null | sed -n 1p)
fixture=''
lsblk() { printf '%s data\n' "$blk"; }
mktemp() { if [ "$*" = -d ] && [ -n "$fixture" ]; then printf '%s\n' "$fixture"; else command mktemp "$@"; fi; }
mount() { :; }
umount() { :; }
rmdir() { [ "$1" = "$fixture" ] || command rmdir "$@"; }
run_wipe() {
    if [ -z "$blk" ]; then
        wipe_user_tree "$1"
        return
    fi
    fixture=$1
    wipe_data_partition fixture-disk data >/dev/null
    fixture=''
    trap 'rm -rf "$work"' EXIT
}

t="$work/t"
vol="$t/containers/storage/volumes"
mkdir -p "$t/pithead/data/monero" "$t/pithead/data/tari" "$t/ssh" "$work/outside/linked" \
    "$work/outside/entry/_data" "$vol/wallet_data/_data/sub" "$vol/caddy_data/_data" \
    "$vol/-x y/_data" "$vol/empty" "$t/containers/storage/overlay/layer"
echo chain >"$t/pithead/data/monero/c"
echo chain >"$t/pithead/data/tari/c"
echo cfg >"$t/pithead/config.json"
echo key >"$t/ssh/host_key"
echo keep >"$work/outside/target"
echo keep >"$work/outside/linked/f"
echo keep >"$work/outside/entry/_data/f"
echo w >"$vol/wallet_data/_data/wallet.db"
echo w >"$vol/wallet_data/_data/.hidden"
echo w >"$vol/wallet_data/_data/sub/x"
ln -s "$work/outside/target" "$vol/wallet_data/_data/link"
echo c >"$vol/caddy_data/_data/cert"
echo d >"$vol/-x y/_data/f"
echo other >"$vol/wallet_data/other"
echo stray >"$vol/stray"
mkdir -p "$vol/linked"
ln -s "$work/outside/linked" "$vol/linked/_data"
ln -s "$work/outside/entry" "$vol/entrylink"
echo layer >"$t/containers/storage/overlay/layer/f"
chmod 700 "$vol/wallet_data/_data"
chmod 750 "$vol/caddy_data/_data"
before_w=$(shape "$vol/wallet_data/_data")
before_c=$(shape "$vol/caddy_data/_data")

run_wipe "$t"

[ "$(cat "$t/pithead/data/monero/c")" = chain ] || fail "monero chain"
[ "$(cat "$t/pithead/data/tari/c")" = chain ] || fail "tari chain"
[ ! -e "$t/pithead/config.json" ] || fail "pithead/ user data kept"
[ ! -e "$t/ssh" ] || fail "ssh/ kept"
for d in wallet_data caddy_data "-x y"; do
    [ -d "$vol/$d/_data" ] && [ -z "$(ls -A "$vol/$d/_data")" ] || fail "volume $d not emptied"
done
[ "$(shape "$vol/wallet_data/_data")" = "$before_w" ] || fail "wallet_data/_data mode or owner"
[ "$(shape "$vol/caddy_data/_data")" = "$before_c" ] || fail "caddy_data/_data mode or owner"
[ "$(cat "$vol/wallet_data/other")" = other ] || fail "volume record file"
[ "$(cat "$vol/stray")" = stray ] || fail "stray volumes entry"
[ "$(cat "$t/containers/storage/overlay/layer/f")" = layer ] || fail "image layer"
[ "$(cat "$work/outside/target")" = keep ] || fail "link target inside a volume"
[ "$(cat "$work/outside/linked/f")" = keep ] || fail "_data link target"
[ -L "$vol/linked/_data" ] || fail "_data link removed"
[ "$(cat "$work/outside/entry/_data/f")" = keep ] || fail "volumes entry link target"
[ ! -e "$t/.wipe-keep.$$" ] || fail "keep folder left behind"

t2="$work/t2"
mkdir -p "$t2/pithead/data/monero" "$t2/containers" "$work/elsewhere/volumes/v/_data"
echo chain >"$t2/pithead/data/monero/c"
echo keep >"$work/elsewhere/volumes/v/_data/f"
ln -s "$work/elsewhere" "$t2/containers/storage"
run_wipe "$t2"
[ "$(cat "$work/elsewhere/volumes/v/_data/f")" = keep ] || fail "store reached through a link"
[ "$(cat "$t2/pithead/data/monero/c")" = chain ] || fail "monero chain without volumes"

t3="$work/t3"
mkdir -p "$t3/pithead/data/tari" "$t3/ssh"
echo chain >"$t3/pithead/data/tari/c"
run_wipe "$t3"
[ "$(cat "$t3/pithead/data/tari/c")" = chain ] && [ ! -e "$t3/ssh" ] || fail "tree without a store"

t4="$work/t4"
mkdir -p "$t4/pithead/data/monero" "$t4/containers/storage/volumes/v/_data"
echo chain >"$t4/pithead/data/monero/c"
echo w >"$t4/containers/storage/volumes/v/_data/f"
find() { return 1; }
set +e
(
    set -e
    run_wipe "$t4"
) 2>/dev/null
rc=$?
set -e
unset -f find
[ "$rc" != 0 ] || fail "a volume that cannot be emptied is reported as wiped"
[ "$(cat "$t4/pithead/data/monero/c")" = chain ] || fail "monero chain after a failed volume wipe"
! compgen -G "$t4/.wipe-keep.*" >/dev/null || fail "keep folder left behind after a failed volume wipe"
echo 'Install wipe=data tree: PASS'
