# shellcheck shell=bash
LOAD_WORKER_PID="" LOAD_WORKER_CONFIG="" LOAD_WORKER_LOG="" LOAD_WORKER_METRICS=""
LOAD_WORKER_NAME="" LOAD_BASELINE_NAMES="" LOAD_BASELINE_COUNT=0 LOAD_SHARES_BEFORE=0

worker_names() {
    on_bench "curl -fsS --max-time 8 http://127.0.0.1:8000/api/state 2>/dev/null | jq -r '.workers[]?.name // empty' | sort -u"
}

start_load_worker() {
    [ "$WORKERS" -ge 3 ] 2>/dev/null || return 0
    local baseline bin stamp names deadline
    baseline="$(worker_names)" || return 1
    [ -n "$baseline" ] || return 1
    stamp="$(date +%s)-$$"
    LOAD_WORKER_NAME="pithead-e2e-load-$stamp"
    LOAD_WORKER_CONFIG="/tmp/$LOAD_WORKER_NAME.json"
    LOAD_WORKER_LOG="/tmp/$LOAD_WORKER_NAME.log"
    LOAD_WORKER_METRICS="/tmp/$LOAD_WORKER_NAME.metrics"
    bin="$(on_miner 'p=$(pgrep -xo xmrig 2>/dev/null || true); [ -z "$p" ] || readlink -f "/proc/$p/exe"; command -v xmrig 2>/dev/null' | head -n1)"
    [ -n "$bin" ] || return 1
    on_miner "jq --arg name $(quote_arg "$LOAD_WORKER_NAME") '.pools[0].user = \$name' $(quote_arg "$MINER_XMRIG_CONFIG") > $(quote_arg "$LOAD_WORKER_CONFIG")" || return 1
    LOAD_WORKER_PID="$(on_miner "nohup $(quote_arg "$bin") --config $(quote_arg "$LOAD_WORKER_CONFIG") --threads=1 >$(quote_arg "$LOAD_WORKER_LOG") 2>&1 & echo \$!")"
    [[ "$LOAD_WORKER_PID" =~ ^[0-9]+$ ]] || return 1
    on_miner "nohup sh -c 'while kill -0 $LOAD_WORKER_PID 2>/dev/null; do ps -p $LOAD_WORKER_PID -o %cpu= -o rss=; sleep 1; done' > $(quote_arg "$LOAD_WORKER_METRICS") 2>/dev/null &" || return 1
    LOAD_BASELINE_NAMES="$baseline" LOAD_BASELINE_COUNT="$(wc -l <<<"$baseline")"
    LOAD_SHARES_BEFORE="$(on_bench "curl -fsS --max-time 8 http://127.0.0.1:8000/api/state 2>/dev/null | jq -r '.shares_window.count // 0'" || echo 0)"
    deadline=$(($(date +%s) + 180))
    while :; do
        names="$(worker_names)"
        if grep -Fqx -- "$LOAD_WORKER_NAME" <<<"$names" && [ "$(wc -l <<<"$names")" -gt "$LOAD_BASELINE_COUNT" ]; then
            WORKERS=$((LOAD_BASELINE_COUNT + 1))
            return 0
        fi
        [ "$(date +%s)" -lt "$deadline" ] || return 1
        sleep 8
    done
}

stop_load_worker() {
    [ -z "$LOAD_WORKER_PID" ] || on_miner "kill $(quote_arg "$LOAD_WORKER_PID") 2>/dev/null || true; rm -f $(quote_arg "$LOAD_WORKER_CONFIG") $(quote_arg "$LOAD_WORKER_LOG") $(quote_arg "$LOAD_WORKER_METRICS")" || true
    LOAD_WORKER_PID=""
}

verify_load_worker() {
    [ -z "$LOAD_WORKER_NAME" ] && return 0
    local names hashes shares latency peaks name
    names="$(worker_names)"
    while IFS= read -r name; do
        [ -z "$name" ] || grep -Fqx -- "$name" <<<"$names" || return 1
    done < <(printf '%s\n%s\n' "$LOAD_BASELINE_NAMES" "$LOAD_WORKER_NAME")
    hashes="$(on_bench "curl -fsS --max-time 8 http://127.0.0.1:8000/api/state 2>/dev/null | jq -r '.stratum.total_hashes // 0'")"
    shares="$(on_bench "curl -fsS --max-time 8 http://127.0.0.1:8000/api/state 2>/dev/null | jq -r '.shares_window.count // 0'")"
    [ "$hashes" -gt 0 ] 2>/dev/null && [ "$shares" -gt "$LOAD_SHARES_BEFORE" ] 2>/dev/null || return 1
    latency="$(on_bench "curl -sS -o /dev/null -w '%{time_total}' --max-time 8 http://127.0.0.1:8000/api/state" || echo null)"
    peaks="$(on_miner "awk 'NF == 2 { if (\$1 > cpu) cpu=\$1; if (\$2 > rss) rss=\$2 } END {printf \"%s %s\", cpu+0, rss+0}' $(quote_arg "$LOAD_WORKER_METRICS")" || true)"
    [[ "$peaks" =~ ^[0-9.]+\ [0-9.]+$ ]] || peaks="0 0"
    on_bench "mkdir -p $(quote_arg "$E2E_DIR/results"); printf '{\"load_worker\":\"%s\",\"peak_cpu_pct\":%s,\"peak_rss_kib\":%s,\"dashboard_latency_s\":%s}\\n' $(quote_arg "$LOAD_WORKER_NAME") ${peaks%% *} ${peaks##* } $latency > $(quote_arg "$E2E_DIR/results/multi-worker-metrics.json")" || true
}
