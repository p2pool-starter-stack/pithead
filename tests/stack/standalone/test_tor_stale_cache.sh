#!/usr/bin/env bash
set -euo pipefail
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)
WORK=$(mktemp -d "${TMPDIR:-${RUNNER_TEMP:-/tmp}}/pithead-tor-stale-cache.XXXXXX")
trap 'rm -rf "$WORK"' EXIT

mkdir -p "$WORK/bin"
printf '#!/bin/sh\nprintf launched >"$TOR_LAUNCH_MARKER"\n' >"$WORK/bin/tor"
chmod +x "$WORK/bin/tor"
printf '#!/bin/sh\nprintf "%%s\\n" "$1" >"$SLEEP_MARKER"\n' >"$WORK/bin/sleep"
chmod +x "$WORK/bin/sleep"
export SLEEP_MARKER="$WORK/slept"

seed() {
    rm -rf "$WORK/data" "$WORK/launched"
    mkdir -p "$WORK/data/p2pool"
    printf 'key\n' >"$WORK/data/p2pool/hs_ed25519_secret_key"
    printf 'guards\n' >"$WORK/data/state"
    printf 'extra\n' >"$WORK/data/cached-extrainfo"
    for name in cached-microdesc-consensus cached-microdescs cached-microdescs.new cached-certs; do
        printf '%s\n' "$name" >"$WORK/data/$name"
    done
    touch -d "@$(($(date +%s) - $1))" "$WORK/data/cached-microdesc-consensus"
}

run_entry() {
    PATH="$WORK/bin:$PATH" TORRC_TEMPLATE="$ROOT/build/tor/torrc.template" TORRC_OUT="$WORK/torrc" \
        TOR_LAUNCH_MARKER="$WORK/launched" TOR_DATA_ROOT="$WORK/data" TOR_CACHE_JITTER_SEC="${TOR_CACHE_JITTER_SEC:-0}" \
        sh "$ROOT/build/tor/entrypoint.sh" 2>&1
}

echo "== a consensus older than the threshold moves the listed cache files aside before Tor starts =="
seed 50000
out=$(run_entry)
grep -q 'moved aside' <<<"$out"
for name in cached-microdesc-consensus cached-microdescs cached-microdescs.new cached-certs; do
    [ ! -e "$WORK/data/$name" ]
    [ "$(cat "$WORK/data/stale-directory-cache/$name")" = "$name" ]
done
[ -f "$WORK/data/state" ]
[ -f "$WORK/data/cached-extrainfo" ]
[ "$(cat "$WORK/data/p2pool/hs_ed25519_secret_key")" = key ]
[ -e "$WORK/launched" ]

echo "== a fresh consensus leaves every file in place =="
seed 600
out=$(run_entry)
if grep -q 'moved aside' <<<"$out"; then exit 1; fi
[ -f "$WORK/data/cached-microdesc-consensus" ]
[ ! -e "$WORK/data/stale-directory-cache" ]
[ -e "$WORK/launched" ]

echo "== a missing consensus is not stale =="
seed 50000
rm "$WORK/data/cached-microdesc-consensus"
run_entry >/dev/null
[ -f "$WORK/data/cached-certs" ]
[ ! -e "$WORK/data/stale-directory-cache" ]

echo "== a symlinked consensus is never followed =="
seed 50000
rm "$WORK/data/cached-microdesc-consensus"
ln -s "$WORK/data/state" "$WORK/data/cached-microdesc-consensus"
run_entry >/dev/null
[ -f "$WORK/data/state" ]
[ ! -e "$WORK/data/stale-directory-cache" ]

echo "== the threshold is configurable =="
seed 600
TOR_STALE_CONSENSUS_SEC=60 run_entry >/dev/null
[ -f "$WORK/data/stale-directory-cache/cached-certs" ]
echo "== the cleanup waits a random time below the jitter bound =="
seed 50000
rm -f "$WORK/slept"
TOR_CACHE_JITTER_SEC=5 run_entry >/dev/null
[ "$(cat "$WORK/slept")" -ge 0 ] && [ "$(cat "$WORK/slept")" -lt 5 ]

echo "== a cleanup that cannot write still starts Tor =="
seed 50000
chmod a-w "$WORK/data"
out=$(run_entry)
chmod u+w "$WORK/data"
grep -q 'cleanup failed' <<<"$out"
[ -e "$WORK/launched" ]
[ -f "$WORK/data/cached-microdesc-consensus" ]
echo 'tor stale cache PASS'
