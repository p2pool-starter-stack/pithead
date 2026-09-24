#!/bin/bash
set -e
#
# Pithead Tari entrypoint wrapper (#183/#234).
#
# pithead renders the canonical *Tor* config (build/tari/config.toml, bind-mounted read-only-ish at
# $TARI_CONFIG_SRC). This wrapper produces the RUNTIME config the node actually uses, then runs the
# node the way upstream's start_tari_app.sh does (WAIT_FOR_TOR, base path) under the fork check below.
#
# It NEVER mutates the canonical config — it copies it to a runtime path and, ONLY when an optional
# clearnet initial sync is active, transforms the copy. "Active" = the flag is on AND the dashboard's
# auto-transition marker is absent (#234); once the chain has synced over clearnet the dashboard
# drops that marker and restarts the container, so this start (and every later one) uses the
# untouched Tor config — the node returns to Tor on its own and stays there.
#
# Clearnet transform: flip the transport tor → tcp, re-enable the seeds.tari.com DNS seed (the
# bundled onion peer_seeds are unreachable without Tor), and stop advertising the onion. The host's
# IP is briefly visible to the Tari P2P network during the sync window.
#
# Dead-fork rewind (#2618). A 5.3.1 node that kept its peers followed the dead branch past the
# 350,000 hard fork. After the 6.0.0 migration it still holds those blocks, bans every canonical
# peer for `Invalid Proof of work` and never converges. So the wrapper no longer execs the node: it
# starts it as a child, waits for gRPC (closed until the migration finishes, #2464), and reads the
# header at FORK_HEIGHT. A tip below it or the canonical hash: the node keeps running under this
# wrapper, which forwards TERM/INT and exits with its status. A different hash: stop it, run
# `rewind-blockchain REWIND_HEIGHT` once, stop it, clear the peer state (the bans), start normally.
# No marker: a canonical node never matches, so the check is safe on every start.

TARI_CONFIG_SRC="${TARI_CONFIG_SRC:-/var/tari/config/config.toml}"
TARI_CONFIG_RUNTIME="${TARI_CONFIG_RUNTIME:-/tmp/tari-runtime-config.toml}"
CLEARNET_MARKER="${CLEARNET_MARKER:-/clearnet-state/tari.synced}"

# Apply the clearnet transform in place to an already-rendered (Tor) config copy. Portable sed
# (no in-place -e) so the shell test suite can exercise it directly.
apply_clearnet_initial_sync() {
    local cfg="$1" tmp="$1.tmp"
    sed -e 's/^type = "tor"/type = "tcp"/' \
        -e 's/^dns_seeds = \[\]/dns_seeds = ["seeds.tari.com"]/' \
        -e 's#^public_addresses = .*#public_addresses = []#' \
        "$cfg" >"$tmp" && mv "$tmp" "$cfg"
}

# True when Tari should sync over clearnet NOW: flag on AND the auto-transition marker absent (#234).
clearnet_sync_active() {
    [ "${TARI_CLEARNET_SYNC:-false}" = "true" ] && [ ! -f "$CLEARNET_MARKER" ]
}

# Render the runtime config from the canonical Tor config, applying clearnet only while active.
render_tari_runtime_config() {
    local src="$1" runtime="$2"
    mkdir -p "$(dirname "$runtime")"
    cp "$src" "$runtime"
    if clearnet_sync_active; then
        apply_clearnet_initial_sync "$runtime"
    fi
}

FORK_HEIGHT=350000
REWIND_HEIGHT=349900
# Canonical mainnet block 350,000 (text explorer JSON and a canonical bench node's ListHeaders, #2618).
CANONICAL_HASH_AT_FORK=663b7254df69989b33cec8325815631e2b455f7252c230976f1b50dc8daced47
TARI_GRPC_URL="${TARI_GRPC_URL:-http://127.0.0.1:18142}"
TARI_PROBE_INTERVAL="${TARI_PROBE_INTERVAL:-10}"
TARI_REWIND_TIMEOUT="${TARI_REWIND_TIMEOUT:-1800}"
TARI_GRPC_ERROR_TIMEOUT="${TARI_GRPC_ERROR_TIMEOUT:-1800}"
NODE_PID=""
STOP_SIGNAL=""

fork_log() { echo "[pithead fork-check] $*"; }

# Protobuf varint at hex offset $2 of $1: sets PB_V (value) and PB_I (offset after it).
pb_varint() {
    local hex="$1" i="$2" shift=0 b v=0
    while :; do
        [ "$i" -lt "${#hex}" ] || return 1
        b=$((16#${hex:i:2}))
        i=$((i + 2))
        v=$((v | ((b & 127) << shift)))
        shift=$((shift + 7))
        [ $((b & 128)) -eq 0 ] && break
    done
    PB_V=$v PB_I=$i
}

# Varint encoding of $1 as hex (request bodies).
pb_encode_varint() {
    local v="$1" out=""
    while [ "$v" -ge 128 ]; do
        out+=$(printf '%02x' $(((v & 127) | 128)))
        v=$((v >> 7))
    done
    printf '%s%02x' "$out" "$v"
}

# First top-level field number $2 of the protobuf message in hex $1: a varint prints as decimal,
# a length-delimited field as hex. Returns 1 when absent (proto3 omits zero values).
pb_field() {
    local hex="$1" want="$2" i=0 key val
    while [ "$i" -lt "${#hex}" ]; do
        pb_varint "$hex" "$i" || return 1
        key=$PB_V i=$PB_I
        case $((key & 7)) in
        0)
            pb_varint "$hex" "$i" || return 1
            val=$PB_V i=$PB_I
            ;;
        1) val=${hex:i:16} i=$((i + 16)) ;;
        2)
            pb_varint "$hex" "$i" || return 1
            val=${hex:PB_I:PB_V*2} i=$((PB_I + PB_V * 2))
            ;;
        5) val=${hex:i:8} i=$((i + 8)) ;;
        *) return 1 ;;
        esac
        [ $((key >> 3)) -eq "$want" ] && {
            echo "$val"
            return 0
        }
    done
    return 1
}

# Unary or server-streaming call on the node's loopback gRPC. Sets GRPC_CODE to the HTTP status,
# GRPC_STATUS/GRPC_ERR to the grpc-status/grpc-message headers or trailers, and GRPC_MSG to the
# first message as hex (empty on any error). Returns 1 only while nothing answers (curl's 000);
# any HTTP status is an answer.
tari_grpc() {
    local method="$1" req="$2" out hdrs code frame len
    out=$(mktemp /tmp/tari-grpc.XXXXXX) || return 1
    hdrs=$(mktemp /tmp/tari-grpc.XXXXXX) || {
        rm -f "$out"
        return 1
    }
    code=$(printf '%b' "$(printf '00%08x%s' $((${#req} / 2)) "$req" | sed 's/../\\x&/g')" |
        curl -s --http2-prior-knowledge --max-time 30 -o "$out" -D "$hdrs" -w '%{http_code}' \
            -H 'content-type: application/grpc' -H 'te: trailers' --data-binary @- \
            -- "$TARI_GRPC_URL/tari.rpc.BaseNode/$method")
    frame=$(od -An -v -tx1 "$out" 2>/dev/null | tr -d ' \n')
    GRPC_STATUS=$(tr -d '\r' <"$hdrs" | sed -n 's/^grpc-status: *//Ip' | tail -1)
    GRPC_ERR=$(tr -d '\r' <"$hdrs" | sed -n 's/^grpc-message: *//Ip' | tail -1)
    rm -f "$out" "$hdrs"
    GRPC_CODE=${code:-000}
    GRPC_MSG=""
    [ "$GRPC_CODE" != 000 ] || return 1
    [ "$GRPC_CODE" = 200 ] || return 0
    [ "${#frame}" -ge 10 ] || return 0
    len=$((16#${frame:2:8}))
    GRPC_MSG=${frame:10:len*2}
}

# The node's header at FORK_HEIGHT: prints its hash, or "below" when the tip is under FORK_HEIGHT
# (ListHeaders clamps from_height to the tip, so a node with any chain returns a header). Returns
# 1 while gRPC is silent; 4, printing the grpc-status, on HTTP 200 with no message: a gRPC error,
# as the server listens before the node is ready; 2, printing the HTTP status, on any other answer
# without a header.
header_at_fork() {
    local header height
    tari_grpc ListHeaders "08$(pb_encode_varint "$FORK_HEIGHT")10011801" || return 1
    if [ "$GRPC_CODE" = 200 ] && [ -z "$GRPC_MSG" ]; then
        echo "grpc-status ${GRPC_STATUS:-unknown}${GRPC_ERR:+: $GRPC_ERR}"
        return 4
    fi
    header=$(pb_field "$GRPC_MSG" 1) || {
        echo "HTTP $GRPC_CODE"
        return 2
    }
    height=$(pb_field "$header" 3) || height=0
    if [ "$height" -ne "$FORK_HEIGHT" ]; then
        echo below
    else
        pb_field "$header" 1 || {
            echo "HTTP $GRPC_CODE"
            return 2
        }
    fi
}

tip_height() {
    local meta
    tari_grpc GetTipInfo "" || return 1
    meta=$(pb_field "$GRPC_MSG" 1) || return 1
    pb_field "$meta" 1 || echo 0
}

start_node() {
    "${APP_EXEC:-minotari_node}" --config "$TARI_CONFIG" --base-path "$TARI_BASE" "$@" &
    NODE_PID=$!
}

node_alive() { kill -0 "$NODE_PID" 2>/dev/null; }

# Forward a container stop to the node as TERM (bash starts background children with SIGINT
# ignored), and remember it so no later phase starts another node.
on_stop_signal() {
    STOP_SIGNAL=$1
    [ -n "$NODE_PID" ] && kill -TERM "$NODE_PID" 2>/dev/null
    return 0
}

# Wait for the node to exit and return its status. A trapped signal interrupts `wait` early, so
# wait again until the child is really gone.
wait_node() {
    local rc
    while :; do
        wait "$NODE_PID"
        rc=$?
        node_alive || return "$rc"
    done
}

stop_node() {
    kill -TERM "$NODE_PID" 2>/dev/null
    wait_node
}

pause() {
    sleep "$TARI_PROBE_INTERVAL" &
    wait $! 2>/dev/null
}

clear_peer_state() {
    fork_log "clearing peer state (bans) under $TARI_BASE"
    find "$TARI_BASE" -maxdepth 4 \( \( -type d -name peer_db \) -o \
        \( -type f \( -name dht.sqlite -o -name dht.sqlite-shm -o -name dht.sqlite-wal \) \) \) \
        -prune -print -exec rm -rf {} +
}

# Wait for gRPC, then check the header at FORK_HEIGHT. Returns 0 when the running node may keep
# running, 3 when it is on the dead branch, and the node's exit status when it stops first.
check_fork() {
    local hash rc err_deadline=""
    fork_log "waiting for gRPC (the 6.0.0 database migration runs first and can take hours)"
    while :; do
        [ -n "$STOP_SIGNAL" ] && return 0
        node_alive || return 0
        hash=$(header_at_fork)
        rc=$?
        if [ "$rc" -eq 4 ]; then
            if [ -z "$err_deadline" ]; then
                err_deadline=$((SECONDS + TARI_GRPC_ERROR_TIMEOUT))
                fork_log "gRPC answered $hash; retrying for up to ${TARI_GRPC_ERROR_TIMEOUT}s while the node starts"
            elif [ "$SECONDS" -ge "$err_deadline" ]; then
                break
            fi
        elif [ "$rc" -ne 1 ]; then
            break
        fi
        pause
    done
    if [ "$rc" -ne 0 ]; then
        fork_log "gRPC answered ($hash) without a header at $FORK_HEIGHT; leaving the node as it is"
    elif [ "$hash" = below ]; then
        fork_log "tip is below $FORK_HEIGHT; nothing to rewind"
    elif [ "$hash" = "$CANONICAL_HASH_AT_FORK" ]; then
        fork_log "header $FORK_HEIGHT is canonical ($hash); nothing to rewind"
    else
        fork_log "header $FORK_HEIGHT is $hash, canonical is $CANONICAL_HASH_AT_FORK: dead 5.3.1 branch"
        return 3
    fi
    return 0
}

# Rewind to REWIND_HEIGHT with a one-shot --watch, stopped as soon as the tip is there (upstream's
# --watch repeats its command until shutdown).
rewind_dead_branch() {
    local deadline=$((SECONDS + TARI_REWIND_TIMEOUT)) tip rc
    fork_log "stopping the node to rewind to $REWIND_HEIGHT"
    stop_node
    [ -n "$STOP_SIGNAL" ] && return 0
    start_node "$@" --watch "rewind-blockchain $REWIND_HEIGHT"
    while :; do
        [ -n "$STOP_SIGNAL" ] && {
            wait_node
            return 0
        }
        if ! node_alive; then
            wait_node
            rc=$?
            fork_log "ERROR: the node exited ($rc) during the rewind"
            return $((rc ? rc : 1))
        fi
        tip=$(tip_height) && [ "$tip" -le "$REWIND_HEIGHT" ] && break
        if [ "$SECONDS" -ge "$deadline" ]; then
            fork_log "ERROR: the tip did not reach $REWIND_HEIGHT within ${TARI_REWIND_TIMEOUT}s"
            stop_node
            return 1
        fi
        pause
    done
    fork_log "rewound to $tip; stopping the node before the normal start"
    stop_node
    [ -n "$STOP_SIGNAL" ] && return 0
    clear_peer_state
}

# Start the node, rewind it off the dead branch if needed, then supervise it until it exits.
run_node() {
    local rc
    trap 'on_stop_signal TERM' TERM
    trap 'on_stop_signal INT' INT
    [ "${WAIT_FOR_TOR:-0}" != 0 ] && sleep "$WAIT_FOR_TOR"
    mkdir -p "$TARI_BASE" && cd "$TARI_BASE" || return 1
    start_node "$@"
    check_fork
    rc=$?
    if [ "$rc" -eq 3 ]; then
        rewind_dead_branch "$@" || return
        [ -n "$STOP_SIGNAL" ] && return 0
        fork_log "starting the node normally"
        start_node "$@"
    fi
    wait_node
}

# Sourced by the test harness (PITHEAD_TEST_SOURCE=1): expose the functions, render nothing, exec
# nothing. `return` works when sourced; the `|| exit` guards a direct run.
if [ "${PITHEAD_TEST_SOURCE:-0}" = "1" ]; then
    return 0 2>/dev/null || exit 0
fi

render_tari_runtime_config "$TARI_CONFIG_SRC" "$TARI_CONFIG_RUNTIME"

if clearnet_sync_active; then
    echo "=========================================================================="
    echo "WARNING: TARI CLEARNET INITIAL SYNC IS ACTIVE (#183)"
    echo "  Tari P2P is running over CLEARNET (TCP + seeds.tari.com DNS seed) to sync"
    echo "  faster — this host's IP is visible to the Tari P2P network for the sync"
    echo "  window. The dashboard switches Tari back to Tor automatically once the"
    echo "  chain is synced (#234)."
    echo "=========================================================================="
elif [ "${TARI_CLEARNET_SYNC:-false}" = "true" ]; then
    echo "Tari clearnet initial sync already completed (#234) — starting Tor-only."
fi

# Run the node the way upstream's start_tari_app.sh does (WAIT_FOR_TOR, base path), but with a
# quoted "$@": its unquoted ${@} would split the --watch argument of the rewind.
# The probe expects non-zero returns, so leave `set -e` behind here.
set +e
case $TARI_GRPC_URL in
http://*) ;;
*)
    fork_log "ERROR: TARI_GRPC_URL must start with http:// (got '$TARI_GRPC_URL')"
    exit 1
    ;;
esac
TARI_CONFIG="$TARI_CONFIG_RUNTIME"
TARI_BASE="${TARI_BASE:-/var/tari/${APP_NAME:-node}}"
run_node "$@"
