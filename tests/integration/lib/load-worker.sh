# shellcheck shell=bash
LOAD_WORKER_DIR="" LOAD_WORKER_CONFIG="" LOAD_WORKER_LOG=""
LOAD_WORKER_NAME="" LOAD_BORROWED_NAME="" LOAD_BASELINE_NAMES="" LOAD_EXPECTED_WORKERS="" LOAD_SHARES_BEFORE=0
LOAD_PEAK_CPU=0 LOAD_PEAK_RSS=0 LOAD_METRICS_SAMPLED=0 LOAD_SAW_READY=0 LOAD_SAW_FAILOVER=0 LOAD_SAW_RECOVERY=0
LOAD_MAX_HASHES=0 LOAD_MAX_SHARES=0 LOAD_MAX_CLONE_SHARES=0
LOAD_WORKER_CONFIG_FILTER='.pools[0].user = $name | .http = {"enabled": false} | .autosave = false | .background = false | del(."log-file")'

worker_names() {
    on_bench "curl -fsS --max-time 8 http://127.0.0.1:8000/api/state 2>/dev/null | jq -r '.workers[]? | select(.status == \"online\") | .name // empty | select(test(\"^[^[:cntrl:]]+$\"))' | sort -u"
}

refresh_load_borrowed_name() {
    [ -n "$LOAD_WORKER_NAME" ] || return 0
    local old="$LOAD_BORROWED_NAME" new
    new="$(on_miner "jq -er '.pools[0].user | strings | select(test(\"^[^[:cntrl:]]+$\"))' $(quote_arg "$MINER_XMRIG_CONFIG")")" || return 1
    if [ -n "$LOAD_BASELINE_NAMES" ] && [ -n "$old" ] && [ "$old" != "$new" ]; then
        LOAD_BASELINE_NAMES="$({
            grep -Fvx -- "$old" <<<"$LOAD_BASELINE_NAMES" || true
            printf '%s\n' "$new"
        } | sort -u)"
    fi
    LOAD_BORROWED_NAME="$new"
}

# Require every worker observed before the clone plus the clone itself. RigForge control can rename
# the borrowed worker; refresh_load_borrowed_name replaces that one baseline label after the re-arm.
worker_set_ready() { # <newline-separated online names, sorted>
    local names="$1" name
    grep -Fxq -- "$LOAD_WORKER_NAME" <<<"$names" || return 1
    while IFS= read -r name; do
        [ -z "$name" ] || grep -Fxq -- "$name" <<<"$names" || return 1
    done <<<"$LOAD_BASELINE_NAMES"
}

wait_load_workers() { # <timeout_s>
    local deadline names
    [ -n "$LOAD_WORKER_NAME" ] || {
        wait_workers "${LOAD_EXPECTED_WORKERS:-$WORKERS}" "$1"
        return
    }
    deadline=$(($(date +%s) + $1))
    while :; do
        names="$(worker_names)"
        worker_set_ready "$names" && return 0
        [ "$(date +%s)" -lt "$deadline" ] || return 1
        sleep 8
    done
}

cleanup_stale_load_workers() {
    local dirs dir
    dirs="$(on_miner "find /tmp -maxdepth 1 -type d -name 'pithead-e2e-load.*' -uid \$(id -u) -print")" || return 1
    while IFS= read -r dir; do
        [ -n "$dir" ] || continue
        LOAD_WORKER_DIR="$dir"
        LOAD_WORKER_CONFIG="$dir/config.json"
        stop_load_worker || return 1
    done <<<"$dirs"
}

start_load_worker() {
    [ "$WORKERS" -eq 3 ] 2>/dev/null || return 0
    local bin stamp identity
    cleanup_stale_load_workers || return 1
    stamp="$(date +%s)-$$"
    LOAD_WORKER_NAME="pithead-e2e-load-$stamp"
    LOAD_WORKER_DIR="$(on_miner 'umask 077; mktemp -d /tmp/pithead-e2e-load.XXXXXX')" || return 1
    if [[ ! "$LOAD_WORKER_DIR" =~ ^/tmp/pithead-e2e-load\.[A-Za-z0-9]+$ ]]; then
        LOAD_WORKER_DIR=""
        return 1
    fi
    LOAD_WORKER_CONFIG="$LOAD_WORKER_DIR/config.json"
    LOAD_WORKER_LOG="$LOAD_WORKER_DIR/xmrig.log"
    refresh_load_borrowed_name || {
        stop_load_worker
        return 1
    }
    LOAD_BASELINE_NAMES="$(worker_names)" || {
        stop_load_worker
        return 1
    }
    grep -Fxq -- "$LOAD_BORROWED_NAME" <<<"$LOAD_BASELINE_NAMES" || {
        stop_load_worker
        return 1
    }
    LOAD_EXPECTED_WORKERS=$(($(grep -c . <<<"$LOAD_BASELINE_NAMES") + 1))
    bin="$(on_miner "for b in $(quote_arg "${MINER_XMRIG_CONFIG%/*}/xmrig") \$(command -v xmrig 2>/dev/null); do [ -x \"\$b\" ] && { printf '%s\\n' \"\$b\"; break; }; done")"
    [ -n "$bin" ] || {
        warn "cannot find the borrowed rig's XMRig binary"
        stop_load_worker
        return 1
    }
    on_miner "umask 077; jq --arg name $(quote_arg "$LOAD_WORKER_NAME") $(quote_arg "$LOAD_WORKER_CONFIG_FILTER") $(quote_arg "$MINER_XMRIG_CONFIG") > $(quote_arg "$LOAD_WORKER_CONFIG")" || {
        stop_load_worker
        return 1
    }
    identity="$(on_miner "umask 077; p=''; start=''; owned() { test -n \"\$p\" && test -r \"/proc/\$p/stat\" || return 1; test -n \"\$start\" || return 2; test \"\$(awk '{print \$22}' \"/proc/\$p/stat\")\" = \"\$start\" || return 2; tr '\\0' '\\n' </proc/\$p/cmdline | grep -Fxq -- $(quote_arg "$LOAD_WORKER_CONFIG") || return 2; }; fail() { trap - EXIT HUP INT TERM; if test -n \"\$p\" && test -z \"\$start\"; then kill -TERM \"\$p\" 2>/dev/null || true; wait \"\$p\" 2>/dev/null || true; rm -rf -- $(quote_arg "$LOAD_WORKER_DIR"); exit 1; fi; owned; x=\$?; test \"\$x\" = 1 && exit 1; test \"\$x\" = 2 && { touch $(quote_arg "$LOAD_WORKER_DIR/cleanup-failed"); exit 1; }; kill -TERM \"\$p\" || true; i=0; while test \"\$i\" -lt 10; do owned; x=\$?; test \"\$x\" = 1 && exit 1; test \"\$x\" = 2 && { touch $(quote_arg "$LOAD_WORKER_DIR/cleanup-failed"); exit 1; }; sleep 1; i=\$((i + 1)); done; owned; x=\$?; test \"\$x\" = 1 && exit 1; test \"\$x\" = 2 && { touch $(quote_arg "$LOAD_WORKER_DIR/cleanup-failed"); exit 1; }; kill -KILL \"\$p\" || true; sleep 1; owned; x=\$?; test \"\$x\" = 1 || touch $(quote_arg "$LOAD_WORKER_DIR/cleanup-failed"); exit 1; }; trap fail EXIT HUP INT TERM; nohup $(quote_arg "$bin") --config $(quote_arg "$LOAD_WORKER_CONFIG") --threads=1 >$(quote_arg "$LOAD_WORKER_LOG") 2>&1 & p=\$!; start=\$(awk '{print \$22}' /proc/\$p/stat) || exit 1; printf '%s %s\\n' \"\$p\" \"\$start\" > $(quote_arg "$LOAD_WORKER_DIR/identity") || exit 1; trap - EXIT HUP INT TERM; printf '%s %s' \"\$p\" \"\$start\"")"
    [[ "$identity" =~ ^([0-9]+)\ ([0-9]+)$ ]] || {
        stop_load_worker
        return 1
    }
    LOAD_SHARES_BEFORE="$(on_bench "curl -fsS --max-time 8 http://127.0.0.1:8000/api/state 2>/dev/null | jq -er '[.workers[]? | select(.status == \"online\") | .accepted | tonumber] | add // 0 | select(type == \"number\" and . >= 0 and floor == .)'")" || {
        stop_load_worker
        return 1
    }
    [[ "$LOAD_SHARES_BEFORE" =~ ^[0-9]+$ ]] || {
        stop_load_worker
        return 1
    }
    LOAD_PEAK_CPU=0 LOAD_PEAK_RSS=0 LOAD_METRICS_SAMPLED=0 LOAD_SAW_READY=0 LOAD_SAW_FAILOVER=0 LOAD_SAW_RECOVERY=0
    LOAD_MAX_HASHES=0 LOAD_MAX_SHARES="$LOAD_SHARES_BEFORE" LOAD_MAX_CLONE_SHARES=0
    wait_load_workers 180 || {
        stop_load_worker
        return 1
    }
}

sample_load_worker() {
    [ -n "$LOAD_WORKER_NAME" ] || return 0
    local state names hashes shares clone_shares proxy_state sample cpu rss
    state="$(on_bench "curl -fsS --max-time 8 http://127.0.0.1:8000/api/state 2>/dev/null")" || state='{}'
    names="$(printf '%s' "$state" | jq -r '.workers[]? | select(.status == "online") | .name // empty | select(test("^[^[:cntrl:]]+$"))' | sort -u)"
    hashes="$(printf '%s' "$state" | jq -r '[.workers[]? | select(.status == "online") | (.h15 // .h60 // 0)] as $r | if all($r[]; type == "number") then (if all($r[]; isfinite and . >= 0) then ($r | add // 0) else 0 end) else 0 end')" || hashes=0
    shares="$(printf '%s' "$state" | jq -r '[.workers[]? | select(.status == "online") | .accepted | tonumber?] | add // 0')" || shares=0
    clone_shares="$(printf '%s' "$state" | jq -r --arg n "$LOAD_WORKER_NAME" 'first(.workers[]? | select(.status == "online" and .name == $n) | (.accepted | tonumber?)) // 0')" || clone_shares=0
    if [[ "$hashes" =~ ^[0-9]+([.][0-9]+)?$ ]]; then LOAD_MAX_HASHES="$(awk -v a="$LOAD_MAX_HASHES" -v b="$hashes" 'BEGIN { print (a > b) ? a : b }')"; fi
    if [[ "$shares" =~ ^[0-9]+$ ]] && [ "$shares" -gt "$LOAD_MAX_SHARES" ]; then LOAD_MAX_SHARES="$shares"; fi
    if [[ "$clone_shares" =~ ^[0-9]+$ ]] && [ "$clone_shares" -gt "$LOAD_MAX_CLONE_SHARES" ]; then LOAD_MAX_CLONE_SHARES="$clone_shares"; fi
    proxy_state="$(on_bench "cd $(quote_arg "$E2E_DIR") || exit 2; services=\$(timeout 8s docker compose ps --services --status running 2>/dev/null) || exit 2; if printf '%s\\n' \"\$services\" | grep -Fxq xmrig-proxy; then echo running; else echo stopped; fi")" || proxy_state=error
    case "$proxy_state" in
    running)
        if worker_set_ready "$names"; then
            [ "$LOAD_SAW_FAILOVER" = 0 ] && LOAD_SAW_READY=1 || LOAD_SAW_RECOVERY=1
        fi
        ;;
    stopped) [ "$LOAD_SAW_READY" = 0 ] || LOAD_SAW_FAILOVER=1 ;;
    esac
    sample="$(on_miner "read -r p start < $(quote_arg "$LOAD_WORKER_DIR/identity") || exit 1; test \"\$(awk '{print \$22}' /proc/\$p/stat 2>/dev/null)\" = \"\$start\" || exit 1; tr '\\0' '\\n' </proc/\$p/cmdline | grep -Fxq -- $(quote_arg "$LOAD_WORKER_CONFIG") || exit 1; ps -p \"\$p\" -o %cpu= -o rss=")" || return 0
    read -r cpu rss <<<"$sample"
    [[ "$cpu" =~ ^[0-9]+([.][0-9]+)?$ && "$rss" =~ ^[0-9]+$ ]] || return 0
    LOAD_METRICS_SAMPLED=1
    LOAD_PEAK_CPU="$(awk -v a="$LOAD_PEAK_CPU" -v b="$cpu" 'BEGIN { print (a > b) ? a : b }')"
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
    on_miner "d=$(quote_arg "$LOAD_WORKER_DIR"); cfg=$(quote_arg "$LOAD_WORKER_CONFIG"); test ! -e \"\$d/cleanup-failed\" || exit 76; p=''; start=''; { test ! -r \"\$d/identity\" || read -r p start < \"\$d/identity\"; } || true; { test \"\$p\" -gt 0 2>/dev/null && test \"\$start\" -gt 0 2>/dev/null; } || { p=''; start=''; }; if test -z \"\$p\"; then for f in /proc/[0-9]*/cmdline; do test -r \"\$f\" || continue; tr '\\0' '\\n' <\"\$f\" | grep -Fxq -- '--config' || continue; tr '\\0' '\\n' <\"\$f\" | grep -Fxq -- \"\$cfg\" || continue; q=\${f#/proc/}; q=\${q%/cmdline}; test -z \"\$p\" || { touch \"\$d/cleanup-failed\"; exit 76; }; p=\$q; done; if test -n \"\$p\"; then start=\$(awk '{print \$22}' \"/proc/\$p/stat\") || { touch \"\$d/cleanup-failed\"; exit 76; }; printf '%s %s\\n' \"\$p\" \"\$start\" >\"\$d/identity\" || { touch \"\$d/cleanup-failed\"; exit 76; }; fi; fi; identity() { test -r \"/proc/\$p/stat\" || return 1; test \"\$(awk '{print \$22}' \"/proc/\$p/stat\")\" = \"\$start\" || return 2; tr '\\0' '\\n' </proc/\$p/cmdline | grep -Fxq -- '--config' && tr '\\0' '\\n' </proc/\$p/cmdline | grep -Fxq -- \"\$cfg\" || return 2; }; stop_one() { identity; x=\$?; test \"\$x\" = 1 && return 0; test \"\$x\" = 2 && return 76; kill -TERM \"\$p\" 2>/dev/null || true; i=0; while test \"\$i\" -lt 30; do identity; x=\$?; test \"\$x\" = 1 && return 0; test \"\$x\" = 2 && return 76; sleep 1; i=\$((i + 1)); done; kill -KILL \"\$p\" || return 1; sleep 1; identity; x=\$?; test \"\$x\" = 1 && return 0; test \"\$x\" = 2 && return 76; return 1; }; rc=0; test -z \"\$p\" || { stop_one; rc=\$?; }; test \"\$rc\" != 0 || rm -rf -- \"\$d\" || rc=1; exit \$rc"
    local rc=$?
    [ "$rc" -ne 0 ] || LOAD_WORKER_DIR=""
    [ "$rc" -eq 0 ] || warn "load worker cleanup could not prove the clone stopped (rc $rc)"
    return "$rc"
}

verify_load_worker() {
    [ -z "$LOAD_WORKER_NAME" ] && return 0
    local latency
    sample_load_worker
    latency="$(on_bench "curl -sS -o /dev/null -w '%{time_total}' --max-time 8 http://127.0.0.1:8000/api/state")" || latency=null
    [[ "$latency" =~ ^[0-9]+(\.[0-9]+)?$ ]] || latency=null
    step "load worker evidence: aggregate=${LOAD_MAX_HASHES}H/s accepted=${LOAD_MAX_SHARES} clone_accepted=${LOAD_MAX_CLONE_SHARES} process_sampled=${LOAD_METRICS_SAMPLED} peak_cpu=${LOAD_PEAK_CPU}% peak_rss=${LOAD_PEAK_RSS}KiB dashboard_latency=${latency}s saw_ready=${LOAD_SAW_READY} saw_failover=${LOAD_SAW_FAILOVER} saw_recovery=${LOAD_SAW_RECOVERY}"
    on_bench "mkdir -p $(quote_arg "$E2E_DIR/results") && printf '{\"load_worker\":\"%s\",\"aggregate_hashrate_hs\":%s,\"accepted\":%s,\"clone_accepted\":%s,\"process_sampled\":%s,\"peak_cpu_pct\":%s,\"peak_rss_kib\":%s,\"dashboard_latency_s\":%s,\"saw_ready\":%s,\"saw_failover\":%s,\"saw_recovery\":%s}\\n' $(quote_arg "$LOAD_WORKER_NAME") $(quote_arg "$LOAD_MAX_HASHES") $(quote_arg "$LOAD_MAX_SHARES") $(quote_arg "$LOAD_MAX_CLONE_SHARES") $(quote_arg "$LOAD_METRICS_SAMPLED") $(quote_arg "$LOAD_PEAK_CPU") $(quote_arg "$LOAD_PEAK_RSS") $(quote_arg "$latency") $(quote_arg "$LOAD_SAW_READY") $(quote_arg "$LOAD_SAW_FAILOVER") $(quote_arg "$LOAD_SAW_RECOVERY") > $(quote_arg "$E2E_DIR/results/multi-worker-metrics.json")" || return 1
    awk -v n="$LOAD_MAX_HASHES" 'BEGIN { exit !(n > 0) }' || {
        warn "load worker check failed: aggregate hashrate not plausible"
        return 1
    }
    [ "$LOAD_MAX_SHARES" -gt "$LOAD_SHARES_BEFORE" ] 2>/dev/null || {
        warn "load worker check failed: accepted shares did not advance (aggregate $LOAD_SHARES_BEFORE -> $LOAD_MAX_SHARES, clone $LOAD_MAX_CLONE_SHARES)"
        return 1
    }
    { [ "$LOAD_SAW_READY" = 1 ] && [ "$LOAD_SAW_FAILOVER" = 1 ] && [ "$LOAD_SAW_RECOVERY" = 1 ]; } || {
        warn "load worker check failed: route/failover transition not observed (ready=$LOAD_SAW_READY failover=$LOAD_SAW_FAILOVER recovery=$LOAD_SAW_RECOVERY)"
        return 1
    }
}
