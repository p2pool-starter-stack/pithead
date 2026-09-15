# shellcheck shell=bash
LOAD_WORKER_DIR="" LOAD_WORKER_CONFIG="" LOAD_WORKER_LOG=""
LOAD_WORKER_NAME="" LOAD_BASELINE_NAMES="" LOAD_BASELINE_COUNT=0 LOAD_SHARES_BEFORE=0
LOAD_PEAK_CPU=0 LOAD_PEAK_RSS=0 LOAD_METRICS_SAMPLED=0 LOAD_SAW_READY=0 LOAD_SAW_FAILOVER=0 LOAD_SAW_RECOVERY=0

worker_names() {
    on_bench "curl -fsS --max-time 8 http://127.0.0.1:8000/api/state 2>/dev/null | jq -r '.workers[]? | select(.status == \"online\") | .name // empty' | sort -u"
}

start_load_worker() {
    [ "$WORKERS" -ge 3 ] 2>/dev/null || return 0
    local baseline bin stamp names expected deadline identity
    baseline="$(worker_names)" || return 1
    [ -n "$baseline" ] || return 1
    stamp="$(date +%s)-$$"
    LOAD_WORKER_NAME="pithead-e2e-load-$stamp"
    LOAD_WORKER_DIR="$(on_miner 'umask 077; mktemp -d /tmp/pithead-e2e-load.XXXXXX')" || return 1
    if [[ ! "$LOAD_WORKER_DIR" =~ ^/tmp/pithead-e2e-load\.[A-Za-z0-9]+$ ]]; then
        LOAD_WORKER_DIR=""
        return 1
    fi
    LOAD_WORKER_CONFIG="$LOAD_WORKER_DIR/config.json"
    LOAD_WORKER_LOG="$LOAD_WORKER_DIR/xmrig.log"
    bin="$(on_miner "for b in $(quote_arg "${MINER_XMRIG_CONFIG%/*}/xmrig") \$(command -v xmrig 2>/dev/null); do [ -x \"\$b\" ] && { printf '%s\\n' \"\$b\"; break; }; done")"
    [ -n "$bin" ] || {
        warn "cannot find the borrowed rig's XMRig binary"
        stop_load_worker
        return 1
    }
    on_miner "umask 077; jq --arg name $(quote_arg "$LOAD_WORKER_NAME") '.pools[0].user = \$name' $(quote_arg "$MINER_XMRIG_CONFIG") > $(quote_arg "$LOAD_WORKER_CONFIG")" || {
        stop_load_worker
        return 1
    }
    identity="$(on_miner "umask 077; p=''; start=''; owned() { test -n \"\$p\" && test -r \"/proc/\$p/stat\" || return 1; test -n \"\$start\" || return 2; test \"\$(awk '{print \$22}' \"/proc/\$p/stat\")\" = \"\$start\" || return 2; tr '\\0' '\\n' </proc/\$p/cmdline | grep -Fxq -- $(quote_arg "$LOAD_WORKER_CONFIG") || return 2; }; fail() { trap - EXIT HUP INT TERM; owned; x=\$?; test \"\$x\" = 1 && exit 1; test \"\$x\" = 2 && { touch $(quote_arg "$LOAD_WORKER_DIR/cleanup-failed"); exit 1; }; kill -TERM \"\$p\" || true; i=0; while test \"\$i\" -lt 10; do owned; x=\$?; test \"\$x\" = 1 && exit 1; test \"\$x\" = 2 && { touch $(quote_arg "$LOAD_WORKER_DIR/cleanup-failed"); exit 1; }; sleep 1; i=\$((i + 1)); done; owned; x=\$?; test \"\$x\" = 1 && exit 1; test \"\$x\" = 2 && { touch $(quote_arg "$LOAD_WORKER_DIR/cleanup-failed"); exit 1; }; kill -KILL \"\$p\" || true; sleep 1; owned; x=\$?; test \"\$x\" = 1 || touch $(quote_arg "$LOAD_WORKER_DIR/cleanup-failed"); exit 1; }; trap fail EXIT HUP INT TERM; nohup $(quote_arg "$bin") --config $(quote_arg "$LOAD_WORKER_CONFIG") --threads=1 >$(quote_arg "$LOAD_WORKER_LOG") 2>&1 & p=\$!; start=\$(awk '{print \$22}' /proc/\$p/stat) || exit 1; printf '%s %s\\n' \"\$p\" \"\$start\" > $(quote_arg "$LOAD_WORKER_DIR/identity") || exit 1; trap - EXIT HUP INT TERM; printf '%s %s' \"\$p\" \"\$start\"")"
    [[ "$identity" =~ ^([0-9]+)\ ([0-9]+)$ ]] || {
        stop_load_worker
        return 1
    }
    LOAD_BASELINE_NAMES="$baseline" LOAD_BASELINE_COUNT="$(wc -l <<<"$baseline")"
    LOAD_SHARES_BEFORE="$(on_bench "curl -fsS --max-time 8 http://127.0.0.1:8000/api/state 2>/dev/null | jq -er '[.workers[]? | select(.status == \"online\") | .accepted | tonumber] | add // 0 | select(type == \"number\" and . >= 0 and floor == .)'")" || {
        stop_load_worker
        return 1
    }
    [[ "$LOAD_SHARES_BEFORE" =~ ^[0-9]+$ ]] || {
        stop_load_worker
        return 1
    }
    LOAD_PEAK_CPU=0 LOAD_PEAK_RSS=0 LOAD_METRICS_SAMPLED=0 LOAD_SAW_READY=0 LOAD_SAW_FAILOVER=0 LOAD_SAW_RECOVERY=0
    expected="$(printf '%s\n%s\n' "$baseline" "$LOAD_WORKER_NAME" | sort -u)"
    deadline=$(($(date +%s) + 180))
    while :; do
        names="$(worker_names)"
        if [ "$names" = "$expected" ] && [ "$(wc -l <<<"$names")" -eq $((LOAD_BASELINE_COUNT + 1)) ]; then
            WORKERS=$((LOAD_BASELINE_COUNT + 1))
            return 0
        fi
        [ "$(date +%s)" -lt "$deadline" ] || {
            stop_load_worker
            return 1
        }
        sleep 8
    done
}

sample_load_worker() {
    [ -n "$LOAD_WORKER_NAME" ] || return 0
    local names expected proxy_state sample cpu rss
    names="$(worker_names)" || names=""
    expected="$(printf '%s\n%s\n' "$LOAD_BASELINE_NAMES" "$LOAD_WORKER_NAME" | sort -u)"
    proxy_state="$(on_bench "cd $(quote_arg "$E2E_DIR") || exit 2; services=\$(docker compose ps --services --status running 2>/dev/null) || exit 2; if printf '%s\\n' \"\$services\" | grep -Fxq xmrig-proxy; then echo running; else echo stopped; fi")" || proxy_state=error
    case "$proxy_state" in
    running)
        if [ "$names" = "$expected" ]; then
            [ "$LOAD_SAW_FAILOVER" = 0 ] && LOAD_SAW_READY=1 || LOAD_SAW_RECOVERY=1
        fi
        ;;
    stopped) [ "$LOAD_SAW_READY" = 0 ] || LOAD_SAW_FAILOVER=1 ;;
    esac
    sample="$(on_miner "read -r p start < $(quote_arg "$LOAD_WORKER_DIR/identity") || exit 1; test \"\$(awk '{print \$22}' /proc/\$p/stat 2>/dev/null)\" = \"\$start\" || exit 1; tr '\\0' '\\n' </proc/\$p/cmdline | grep -Fxq -- $(quote_arg "$LOAD_WORKER_CONFIG") || exit 1; ps -p \"\$p\" -o %cpu= -o rss=")" || return 0
    read -r cpu rss <<<"$sample"
    [[ "$cpu" =~ ^[0-9]+([.][0-9]+)?$ && "$rss" =~ ^[0-9]+$ ]] || return 0
    LOAD_METRICS_SAMPLED=1
    LOAD_PEAK_CPU="$(awk -v a="$LOAD_PEAK_CPU" -v b="$cpu" 'BEGIN { print a > b ? a : b }')"
    [ "$rss" -le "$LOAD_PEAK_RSS" ] || LOAD_PEAK_RSS="$rss"
}

load_worker_wait_tick() {
    for _ in {1..4}; do
        sleep 5
        sample_load_worker
    done
}

stop_load_worker() {
    [ -z "$LOAD_WORKER_DIR" ] && return 0
    if [[ ! "$LOAD_WORKER_DIR" =~ ^/tmp/pithead-e2e-load\.[A-Za-z0-9]+$ ]]; then
        warn "refusing an invalid load worker cleanup directory"
        return 1
    fi
    on_miner "d=$(quote_arg "$LOAD_WORKER_DIR"); test ! -e \"\$d/cleanup-failed\" || exit 76; p=''; start=''; test -r \"\$d/identity\" && read -r p start < \"\$d/identity\"; identity() { test -r \"/proc/\$p/stat\" || return 1; test \"\$(awk '{print \$22}' \"/proc/\$p/stat\")\" = \"\$start\" || return 2; tr '\\0' '\\n' </proc/\$p/cmdline | grep -Fxq -- '--config' && tr '\\0' '\\n' </proc/\$p/cmdline | grep -Fxq -- $(quote_arg "$LOAD_WORKER_CONFIG") || return 2; }; stop_one() { identity; x=\$?; test \"\$x\" = 1 && return 0; test \"\$x\" = 2 && return 76; kill -TERM \"\$p\" 2>/dev/null || true; i=0; while test \"\$i\" -lt 30; do identity; x=\$?; test \"\$x\" = 1 && return 0; test \"\$x\" = 2 && return 76; sleep 1; i=\$((i + 1)); done; kill -KILL \"\$p\" || return 1; sleep 1; identity; x=\$?; test \"\$x\" = 1 && return 0; test \"\$x\" = 2 && return 76; return 1; }; rc=0; test -z \"\$p\" || { stop_one; rc=\$?; }; test \"\$rc\" != 0 || rm -rf -- \"\$d\" || rc=1; exit \$rc"
    local rc=$?
    [ "$rc" -ne 0 ] || LOAD_WORKER_DIR=""
    [ "$rc" -eq 0 ] || warn "load worker cleanup could not prove the clone stopped (rc $rc)"
    return "$rc"
}

verify_load_worker() {
    [ -z "$LOAD_WORKER_NAME" ] && return 0
    local state names expected hashes shares clone_shares latency
    sample_load_worker
    state="$(on_bench "curl -fsS --max-time 8 http://127.0.0.1:8000/api/state 2>/dev/null")" || state='{}'
    names="$(printf '%s' "$state" | jq -r '.workers[]? | select(.status == "online") | .name // empty' | sort -u)"
    expected="$(printf '%s\n%s\n' "$LOAD_BASELINE_NAMES" "$LOAD_WORKER_NAME" | sort -u)"
    hashes="$(printf '%s' "$state" | jq '[.workers[]? | select(.status == "online") | (.h15 // .h60 // 0 | numbers)] | add // 0')" || hashes=0
    shares="$(printf '%s' "$state" | jq '[.workers[]? | select(.status == "online") | .accepted | tonumber?] | add // 0')" || shares=0
    clone_shares="$(printf '%s' "$state" | jq -r --arg n "$LOAD_WORKER_NAME" 'first(.workers[]? | select(.status == "online" and .name == $n) | (.accepted | tonumber?)) // 0')" || clone_shares=0
    latency="$(on_bench "curl -sS -o /dev/null -w '%{time_total}' --max-time 8 http://127.0.0.1:8000/api/state")" || latency=null
    [[ "$latency" =~ ^[0-9]+(\.[0-9]+)?$ ]] || latency=null
    step "load worker evidence: aggregate=${hashes}H/s accepted=${shares} clone_accepted=${clone_shares} process_sampled=${LOAD_METRICS_SAMPLED} peak_cpu=${LOAD_PEAK_CPU}% peak_rss=${LOAD_PEAK_RSS}KiB dashboard_latency=${latency}s"
    on_bench "mkdir -p $(quote_arg "$E2E_DIR/results") && printf '{\"load_worker\":\"%s\",\"aggregate_hashrate_hs\":%s,\"accepted\":%s,\"clone_accepted\":%s,\"process_sampled\":%s,\"peak_cpu_pct\":%s,\"peak_rss_kib\":%s,\"dashboard_latency_s\":%s}\\n' $(quote_arg "$LOAD_WORKER_NAME") $(quote_arg "$hashes") $(quote_arg "$shares") $(quote_arg "$clone_shares") $(quote_arg "$LOAD_METRICS_SAMPLED") $(quote_arg "$LOAD_PEAK_CPU") $(quote_arg "$LOAD_PEAK_RSS") $(quote_arg "$latency") > $(quote_arg "$E2E_DIR/results/multi-worker-metrics.json")" || return 1
    [ "$names" = "$expected" ] || return 1
    printf '%s' "$state" | jq -e --argjson workers "$WORKERS" '[.workers[]? | select(.status == "online") | (.h15 // .h60 // 0 | numbers)] as $r | select(($r | length) == $workers and all($r[]; . >= 0)) | $r | add | select(. > 0)' >/dev/null || return 1
    [ "$shares" -gt "$LOAD_SHARES_BEFORE" ] 2>/dev/null && [ "$clone_shares" -gt 0 ] 2>/dev/null || return 1
    [ "$LOAD_SAW_READY" = 1 ] && [ "$LOAD_SAW_FAILOVER" = 1 ] && [ "$LOAD_SAW_RECOVERY" = 1 ] || return 1
}
