# shellcheck shell=bash
: "${STACK_SUITE:?is unset: this file is a tests/stack/run.sh fragment, not a script — run tests/stack/run.sh}"
# Tari dead-fork rewind (#2618): build/tari/entrypoint.sh starts minotari_node as a child, reads the
# header at 350,000 over loopback gRPC and rewinds a node left on the dead 5.3.1 branch. Runs the
# real wrapper with a stub minotari_node and a stub curl that answers gRPC from a state dir.

echo "== unit: tari entrypoint dead-fork rewind (#2618) =="
TFR_ENTRY="$ROOT/build/tari/entrypoint.sh"
TFR_CANONICAL=663b7254df69989b33cec8325815631e2b455f7252c230976f1b50dc8daced47
TFR_DEAD=$(printf 'dead%.0s' {1..16})
mk_tmpdir TFR_BIN

# Stub node: records its argv and signals, opens "gRPC" unless TFR_GRPC_SILENT, and in --watch mode
# plays the rewind (tip -> 349900) on every tick, like upstream's repeating --watch.
cat >"$TFR_BIN/minotari_node" <<'EOF'
#!/usr/bin/env bash
S="$TFR_STATE"
printf '%s|' "$@" >>"$S/starts"
echo >>"$S/starts"
trap 'echo TERM >>"$S/signals"; rm -f "$S/grpc_up"; exit 143' TERM
if [ -n "${TFR_NODE_EXIT:-}" ]; then sleep 0.2; exit "$TFR_NODE_EXIT"; fi
[ -n "${TFR_GRPC_SILENT:-}" ] || : >"$S/grpc_up"
watch=0
for a in "$@"; do [ "$a" = --watch ] && watch=1; done
while :; do
    if [ "$watch" = 1 ] && [ -z "${TFR_REWIND_STUCK:-}" ]; then
        echo 349900 >"$S/tip"
    fi
    sleep 0.1 &
    wait $!
done
EOF
# Stub curl: refuses while gRPC is closed; answers TFR_HTTP_CODE with no body when set; otherwise
# frames a ListHeaders or GetTipInfo answer from the state dir's tip and hash. It keeps the request
# body it was sent and whether the URL came after `--`.
cat >"$TFR_BIN/curl" <<'EOF'
#!/usr/bin/env bash
S="$TFR_STATE" out="" url="" prev=""
while [ $# -gt 0 ]; do
    case $1 in
        -o) out=$2; shift ;;
        -w | -H | --max-time | --data-binary) shift ;;
        http*) url=$1; echo "$prev" >"$S/url.prev" ;;
    esac
    prev=$1
    shift
done
req=$(od -An -v -tx1 | tr -d ' \n')
[ -f "$S/grpc_up" ] || { printf 000; exit 7; }
[ -n "${TFR_HTTP_CODE:-}" ] && { printf '%s' "$TFR_HTTP_CODE"; exit 0; }
# shellcheck disable=SC1090
PITHEAD_TEST_SOURCE=1 source "$TFR_ENTRY"
tip=$(cat "$S/tip")
case $url in
    */ListHeaders)
        echo "$req" >"$S/req.ListHeaders"
        h=$tip
        [ "$tip" -ge 350000 ] && h=350000
        hdr="0a20$(cat "$S/hash")18$(pb_encode_varint "$h")"
        msg="0a$(printf %02x $((${#hdr} / 2)))$hdr" ;;
    */GetTipInfo)
        meta="08$(pb_encode_varint "$tip")"
        msg="0a$(printf %02x $((${#meta} / 2)))$meta" ;;
esac
printf '%b' "$(printf '00%08x%s' $((${#msg} / 2)) "$msg" | sed 's/../\\x&/g')" >"$out"
printf 200
EOF
chmod +x "$TFR_BIN/minotari_node" "$TFR_BIN/curl"

tfr_wait() { # <file> <pattern>: up to 10 s for the pattern to appear in the file
    local n=0
    until grep -q -- "$2" "$1" 2>/dev/null; do
        n=$((n + 1))
        [ "$n" -ge 100 ] && return 1
        sleep 0.1
    done
}

# tfr_start <tip> <hash at 350000> [env...]: runs the wrapper in the background with a fresh state
# and data dir; sets TFR_STATE and TFR_PID. Output goes to $TFR_STATE/out.
tfr_start() {
    local tip=$1 hash=$2
    shift 2
    mk_tmpdir TFR_STATE
    echo "$tip" >"$TFR_STATE/tip"
    echo "$hash" >"$TFR_STATE/hash"
    : >"$TFR_STATE/starts"
    mkdir -p "$TFR_STATE/base/data/base_node/peer_db" "$TFR_STATE/base/data/base_node/db"
    : >"$TFR_STATE/base/data/base_node/db/data.mdb"
    for f in dht.sqlite dht.sqlite-shm dht.sqlite-wal; do : >"$TFR_STATE/base/data/base_node/$f"; done
    printf 'type = "tor"\n' >"$TFR_STATE/config.toml"
    env PATH="$TFR_BIN:$PATH" TFR_STATE="$TFR_STATE" TFR_ENTRY="$TFR_ENTRY" WAIT_FOR_TOR=0 \
        TARI_BASE="$TFR_STATE/base" TARI_CONFIG_SRC="$TFR_STATE/config.toml" \
        TARI_CONFIG_RUNTIME="$TFR_STATE/rt.toml" CLEARNET_MARKER="$TFR_STATE/none" \
        APP_EXEC=minotari_node TARI_PROBE_INTERVAL=0.1 "$@" \
        bash "$TFR_ENTRY" --disable-splash-screen --non-interactive >"$TFR_STATE/out" 2>&1 &
    TFR_PID=$!
}

tfr_has() { if [ -e "$1" ]; then echo yes; else echo no; fi; }

tfr_stop() { # TERM the wrapper as docker/podman stop does; sets TFR_RC
    kill -TERM "$TFR_PID"
    wait "$TFR_PID"
    TFR_RC=$?
}

assert_eq "fork-check: 350000 encodes as the varint b0ae15 (#2618)" \
    "$(PITHEAD_TEST_SOURCE=1 bash -c 'source "$1"; pb_encode_varint 350000' _ "$TFR_ENTRY")" "b0ae15"

# Canonical node past the fork: one start, no rewind, stays up under the wrapper, TERM reaches it.
tfr_start 350500 "$TFR_CANONICAL"
tfr_wait "$TFR_STATE/out" "is canonical"
assert_eq "fork-check: ListHeaders asks for 1 header from 350000, ascending (#2618)" \
    "$(cat "$TFR_STATE/req.ListHeaders" 2>/dev/null)" "000000000808b0ae1510011801"
assert_contains "fork-check: canonical hash logged (#2618)" "$(cat "$TFR_STATE/out")" "header 350000 is canonical ($TFR_CANONICAL)"
sleep 0.3
tfr_stop
assert_eq "fork-check: canonical node started once, without --watch (#2618)" \
    "$(cat "$TFR_STATE/starts")" "--config|$TFR_STATE/rt.toml|--base-path|$TFR_STATE/base|--disable-splash-screen|--non-interactive|"
assert_eq "fork-check: container TERM reaches the supervised node (#2618)" "$(cat "$TFR_STATE/signals" 2>/dev/null)" "TERM"
assert_rc "fork-check: the wrapper exits with the node's status after a stop (#2618)" "$TFR_RC" "143"
assert_eq "fork-check: curl gets -- before the gRPC URL (#2618)" "$(cat "$TFR_STATE/url.prev" 2>/dev/null)" "--"
assert_eq "fork-check: the gRPC response file is removed (#2618)" "$(find /tmp -maxdepth 1 -name 'tari-grpc.*' -newer "$TFR_STATE/tip" | wc -l | tr -d ' ')" "0"
assert_eq "fork-check: canonical node keeps its peer state (#2618)" "$(tfr_has "$TFR_STATE/base/data/base_node/peer_db")" "yes"

# Tip below the fork (production stalled at 349,880): nothing touched.
tfr_start 349880 "$TFR_DEAD"
tfr_wait "$TFR_STATE/out" "below 350000"
assert_contains "fork-check: tip below 350000 logs nothing to rewind (#2618)" "$(cat "$TFR_STATE/out")" "tip is below 350000; nothing to rewind"
tfr_stop
assert_eq "fork-check: below-fork node started once (#2618)" "$(grep -c . "$TFR_STATE/starts")" "1"
assert_eq "fork-check: below-fork database not rewound (#2618)" "$(cat "$TFR_STATE/tip")" "349880"
assert_eq "fork-check: below-fork node keeps its peer state (#2618)" "$(tfr_has "$TFR_STATE/base/data/base_node/dht.sqlite")" "yes"

# Dead branch: stop, one-shot rewind to 349900 with a quoted --watch, stop, clear peers, start normally.
tfr_start 350239 "$TFR_DEAD"
tfr_wait "$TFR_STATE/out" "starting the node normally"
sleep 0.3
tfr_stop
TFR_OUT=$(cat "$TFR_STATE/out")
TFR_BASEARGS="--config|$TFR_STATE/rt.toml|--base-path|$TFR_STATE/base|--disable-splash-screen|--non-interactive|"
assert_contains "fork-check: dead hash and canonical hash both logged (#2618)" "$TFR_OUT" \
    "header 350000 is $TFR_DEAD, canonical is $TFR_CANONICAL: dead 5.3.1 branch"
assert_eq "fork-check: dead branch runs normal, rewind, normal starts; --watch stays one argument (#2618)" \
    "$(cat "$TFR_STATE/starts")" "$TFR_BASEARGS
$TFR_BASEARGS--watch|rewind-blockchain 349900|
$TFR_BASEARGS"
assert_eq "fork-check: the probe node, the rewind node and the final node each got TERM (#2618)" \
    "$(grep -c TERM "$TFR_STATE/signals")" "3"
assert_contains "fork-check: rewind stops once the tip reaches 349900 (#2618)" "$TFR_OUT" "rewound to 349900"
assert_eq "fork-check: rewind path clears peer_db (#2618)" "$(tfr_has "$TFR_STATE/base/data/base_node/peer_db")" "no"
assert_eq "fork-check: rewind path clears dht.sqlite and its -shm/-wal (#2618)" \
    "$(find "$TFR_STATE/base" -name 'dht.sqlite*' | wc -l | tr -d ' ')" "0"
assert_eq "fork-check: rewind path keeps the blockchain database (#2618)" "$(tfr_has "$TFR_STATE/base/data/base_node/db/data.mdb")" "yes"
assert_rc "fork-check: the final node's stop status is the wrapper's (#2618)" "$TFR_RC" "143"

# The node's own failure (DatabaseError 114 mid-migration) is the container's exit status.
tfr_start 350239 "$TFR_DEAD" TFR_NODE_EXIT=114
wait "$TFR_PID"
assert_rc "fork-check: node exit 114 during the migration passes through the wrapper (#2618)" "$?" "114"

# A stop while gRPC is still closed (migration running) stops the node and starts nothing else.
tfr_start 350239 "$TFR_DEAD" TFR_GRPC_SILENT=1
tfr_wait "$TFR_STATE/out" "waiting for gRPC"
sleep 0.3
tfr_stop
assert_eq "fork-check: TERM during the migration reaches the node (#2618)" "$(cat "$TFR_STATE/signals" 2>/dev/null)" "TERM"
assert_eq "fork-check: TERM during the migration starts no second node (#2618)" "$(grep -c . "$TFR_STATE/starts")" "1"

# A rewind that never lands fails loudly instead of leaving --watch running.
tfr_start 350239 "$TFR_DEAD" TFR_REWIND_STUCK=1 TARI_REWIND_TIMEOUT=1
wait "$TFR_PID"
TFR_RC=$?
assert_rc "fork-check: a rewind that times out exits non-zero (#2618)" "$TFR_RC" "1"
assert_contains "fork-check: a rewind timeout is logged (#2618)" "$(cat "$TFR_STATE/out")" "ERROR: the tip did not reach 349900 within 1s"
assert_eq "fork-check: the stuck rewind node is stopped, no normal start follows (#2618)" \
    "$(grep -c . "$TFR_STATE/starts"),$(grep -c TERM "$TFR_STATE/signals")" "2,2"

# gRPC that answers with an HTTP error is an answer: the check ends, logs it and leaves the node alone.
tfr_start 350239 "$TFR_DEAD" TFR_HTTP_CODE=500
tfr_wait "$TFR_STATE/out" "without a header"
assert_contains "fork-check: an HTTP 500 answer is logged, not polled forever (#2618)" "$(cat "$TFR_STATE/out")" \
    "gRPC answered (HTTP 500) without a header at 350000; leaving the node as it is"
tfr_stop
assert_eq "fork-check: an HTTP 500 answer starts no second node (#2618)" "$(grep -c . "$TFR_STATE/starts")" "1"
assert_eq "fork-check: an HTTP 500 answer keeps the peer state (#2618)" "$(tfr_has "$TFR_STATE/base/data/base_node/peer_db")" "yes"

# TARI_GRPC_URL must be an http:// URL: anything else, such as a curl option, is refused before the node starts.
tfr_start 350239 "$TFR_DEAD" TARI_GRPC_URL=-K/etc/passwd
wait "$TFR_PID"
assert_rc "fork-check: a TARI_GRPC_URL without http:// exits 1 (#2618)" "$?" "1"
assert_contains "fork-check: a bad TARI_GRPC_URL is logged (#2618)" "$(cat "$TFR_STATE/out")" "ERROR: TARI_GRPC_URL must start with http://"
assert_eq "fork-check: a bad TARI_GRPC_URL starts no node (#2618)" "$(grep -c . "$TFR_STATE/starts")" "0"
