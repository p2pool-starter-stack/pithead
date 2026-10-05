# shellcheck shell=bash
#
# Wait for the baseline's mining services before the restore proof grades them (#3152).
#
# Sourced by e2e.sh, which supplies on_bench/ok/warn and RESTORE_DIR. The restore re-arms the sync
# gate (#35, #2763): "synced" and "healthy" can both read true before the dashboard's next poll
# starts P2Pool and xmrig-proxy again, and grade_restore_identity then reports `not-running`, which
# discards a correct restore (bench-ci#1277, #1298). Two consecutive running samples, as
# assert_mining_probe_ready requires of the source-image fixture (#3130), reject a transient start.
# The wait only delays the proof: the proof still fails for any service that is not running.

_restore_mining_running() { # -> 0 when p2pool and xmrig-proxy are both running now
    on_bench "cd '$RESTORE_DIR' && running=\$(timeout --kill-after=2 10 docker compose ps --services --status running) && grep -Fxq p2pool <<<\"\$running\" && grep -Fxq xmrig-proxy <<<\"\$running\""
}

# Fixed grammar only: the gate marker and each service's container state, never values.
restore_mining_diagnostics() {
    local out
    out="$(on_bench "cd '$RESTORE_DIR' && bash -s" 2>/dev/null <<'PROBE'
marker=unknown
if timeout --kill-after=2 10 docker compose exec -T dashboard test -e /data/sync-gate-reset 2>/dev/null; then marker=present
elif timeout --kill-after=2 10 docker compose exec -T dashboard true 2>/dev/null; then marker=absent; fi
st() {
    cid=$(timeout --kill-after=2 10 docker compose ps -aq "$1" 2>/dev/null | head -n1)
    if [ -z "$cid" ]; then echo missing; return; fi
    s=$(timeout --kill-after=2 10 docker inspect --format '{{.State.Status}}' "$cid" 2>/dev/null)
    case "$s" in running | exited | restarting | paused | created | dead | removing) echo "$s" ;; *) echo unknown ;; esac
}
echo "restore-mining: stage=mining-services marker=$marker p2pool=$(st p2pool) proxy=$(st xmrig-proxy)"
PROBE
    )" || out=""
    out="$(printf '%s\n' "$out" | grep -E '^restore-mining: stage=mining-services marker=(present|absent|unknown) p2pool=[a-z]+ proxy=[a-z]+$' | head -n1)"
    printf '%s\n' "${out:-restore-mining: stage=mining-services marker=unknown p2pool=unknown proxy=unknown}"
}

wait_restore_mining_ready() { # <timeout_s> [interval_s]
    local deadline=$(($(date +%s) + ${1:-1500})) samples=0 diag
    while :; do
        if _restore_mining_running; then samples=$((samples + 1)); else samples=0; fi
        if [ "$samples" -ge 2 ]; then
            ok "P2Pool and xmrig-proxy running in consecutive samples before the restore proof"
            return 0
        fi
        if [ "$(date +%s)" -ge "$deadline" ]; then
            diag="$(restore_mining_diagnostics)"
            warn "mining services not running for two consecutive samples within ${1:-1500}s — baseline proof stage: mining-services"
            warn "  $diag"
            return 1
        fi
        sleep "${2:-5}"
    done
}
