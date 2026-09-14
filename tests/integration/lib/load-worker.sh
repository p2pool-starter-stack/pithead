# shellcheck shell=bash
LOAD_WORKER_DIR="" LOAD_WORKER_PID="" LOAD_WORKER_CONFIG="" LOAD_WORKER_LOG="" LOAD_WORKER_METRICS=""
LOAD_WORKER_NAME="" LOAD_BASELINE_NAMES="" LOAD_BASELINE_COUNT=0 LOAD_SHARES_BEFORE=0

worker_names() {
    on_bench "curl -fsS --max-time 8 http://127.0.0.1:8000/api/state 2>/dev/null | jq -r '.workers[]?.name // empty' | sort -u"
}

start_load_worker() {
    [ "$WORKERS" -ge 3 ] 2>/dev/null || return 0
    local baseline bin stamp names deadline identity
    baseline="$(worker_names)" || return 1
    [ -n "$baseline" ] || return 1
    stamp="$(date +%s)-$$"
    LOAD_WORKER_NAME="pithead-e2e-load-$stamp"
    LOAD_WORKER_DIR="$(on_miner 'umask 077; mktemp -d /tmp/pithead-e2e-load.XXXXXX')" || return 1
    [[ "$LOAD_WORKER_DIR" =~ ^/tmp/pithead-e2e-load\.[A-Za-z0-9]+$ ]] || return 1
    LOAD_WORKER_CONFIG="$LOAD_WORKER_DIR/config.json"
    LOAD_WORKER_LOG="$LOAD_WORKER_DIR/xmrig.log"
    LOAD_WORKER_METRICS="$LOAD_WORKER_DIR/metrics"
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
    identity="$(on_miner "umask 077; nohup $(quote_arg "$bin") --config $(quote_arg "$LOAD_WORKER_CONFIG") --threads=1 >$(quote_arg "$LOAD_WORKER_LOG") 2>&1 & p=\$!; start=\$(awk '{print \$22}' /proc/\$p/stat) || exit 1; printf '%s %s\\n' \"\$p\" \"\$start\" > $(quote_arg "$LOAD_WORKER_DIR/identity"); printf '%s %s' \"\$p\" \"\$start\"")"
    [[ "$identity" =~ ^([0-9]+)\ ([0-9]+)$ ]] || {
        stop_load_worker
        return 1
    }
    LOAD_WORKER_PID="${BASH_REMATCH[1]}"
    on_miner "umask 077; nohup sh -c 'while kill -0 $LOAD_WORKER_PID 2>/dev/null; do ps -p $LOAD_WORKER_PID -o %cpu= -o rss=; sleep 1; done' > $(quote_arg "$LOAD_WORKER_METRICS") 2>/dev/null &" || {
        stop_load_worker
        return 1
    }
    LOAD_BASELINE_NAMES="$baseline" LOAD_BASELINE_COUNT="$(wc -l <<<"$baseline")"
    LOAD_SHARES_BEFORE="$(on_bench "curl -fsS --max-time 8 http://127.0.0.1:8000/api/state 2>/dev/null | jq '[.workers[]?.accepted | tonumber?] | add // 0'" || echo 0)"
    deadline=$(($(date +%s) + 180))
    while :; do
        names="$(worker_names)"
        if grep -Fqx -- "$LOAD_WORKER_NAME" <<<"$names" && [ "$(wc -l <<<"$names")" -eq $((LOAD_BASELINE_COUNT + 1)) ]; then
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

stop_load_worker() {
    [ -z "$LOAD_WORKER_DIR" ] && return 0
    on_miner "d=$(quote_arg "$LOAD_WORKER_DIR"); p=''; start=''; test -r \"\$d/identity\" && read -r p start < \"\$d/identity\"; identity() { test -r \"/proc/\$p/stat\" || return 1; test \"\$(awk '{print \$22}' \"/proc/\$p/stat\")\" = \"\$start\" || return 2; tr '\\0' '\\n' </proc/\$p/cmdline | grep -Fxq -- '--config' && tr '\\0' '\\n' </proc/\$p/cmdline | grep -Fxq -- $(quote_arg "$LOAD_WORKER_CONFIG"); }; rc=0; test -z \"\$p\" || { identity; rc=\$?; if test \"\$rc\" = 0; then kill -TERM \"\$p\" || rc=1; for i in {1..30}; do identity || { rc=0; break; }; sleep 1; done; identity && { kill -KILL \"\$p\" || rc=1; sleep 1; identity && rc=1; }; elif test \"\$rc\" != 1; then rc=76; fi; }; rm -rf -- \"\$d\" || rc=1; exit \$rc"
    local rc=$?
    LOAD_WORKER_DIR="" LOAD_WORKER_PID=""
    [ "$rc" -eq 0 ] || warn "load worker cleanup could not prove the clone stopped (rc $rc)"
    return "$rc"
}

verify_load_worker() {
    [ -z "$LOAD_WORKER_NAME" ] && return 0
    local names expected hashes shares latency peaks
    names="$(worker_names)"
    expected="$(printf '%s\n%s\n' "$LOAD_BASELINE_NAMES" "$LOAD_WORKER_NAME" | sort -u)"
    [ "$names" = "$expected" ] || return 1
    hashes="$(on_bench "curl -fsS --max-time 8 http://127.0.0.1:8000/api/state 2>/dev/null | jq '[.workers[]? | select(.status == \"online\") | (.h15 // .h60 // 0)] | add // 0'")"
    shares="$(on_bench "curl -fsS --max-time 8 http://127.0.0.1:8000/api/state 2>/dev/null | jq '[.workers[]?.accepted | tonumber?] | add // 0'")"
    [ "$hashes" -gt 0 ] 2>/dev/null && [ "$shares" -gt "$LOAD_SHARES_BEFORE" ] 2>/dev/null || return 1
    latency="$(on_bench "curl -sS -o /dev/null -w '%{time_total}' --max-time 8 http://127.0.0.1:8000/api/state" || echo null)"
    [[ "$latency" =~ ^[0-9]+(\.[0-9]+)?$ ]] || return 1
    peaks="$(on_miner "awk 'NF == 2 { if (\$1 > cpu) cpu=\$1; if (\$2 > rss) rss=\$2 } END {printf \"%s %s\", cpu+0, rss+0}' $(quote_arg "$LOAD_WORKER_METRICS")" || true)"
    [[ "$peaks" =~ ^[0-9.]+\ [0-9.]+$ ]] || peaks="0 0"
    on_bench "mkdir -p $(quote_arg "$E2E_DIR/results") && printf '{\"load_worker\":\"%s\",\"peak_cpu_pct\":%s,\"peak_rss_kib\":%s,\"dashboard_latency_s\":%s}\\n' $(quote_arg "$LOAD_WORKER_NAME") ${peaks%% *} ${peaks##* } $latency > $(quote_arg "$E2E_DIR/results/multi-worker-metrics.json")" || return 1
}
