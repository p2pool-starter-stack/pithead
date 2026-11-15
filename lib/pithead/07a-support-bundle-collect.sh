readonly PITHEAD_SUPPORT_DEFAULT_HOURS=72
readonly PITHEAD_SUPPORT_MAX_HOURS=168
readonly PITHEAD_SUPPORT_UNITS="pithead-boot.service pithead-boot-version.service pithead-address-watch.service pithead-miner-recovery.service dashboard.service caddy.service tor.service monerod.service tari.service p2pool.service xmrig-proxy.service docker-proxy.service docker-control.service xmrig.service rauc.service"

bundle_support_clamp_hours() {
    local h="$1"
    case "$h" in
    '' | *[!0-9]*)
        printf '%s' "$PITHEAD_SUPPORT_DEFAULT_HOURS"
        return 0
        ;;
    *[!0]*)
        h=${h#"${h%%[!0]*}"}
        ;;
    *) h=0 ;;
    esac
    [ "${#h}" -gt "${#PITHEAD_SUPPORT_MAX_HOURS}" ] && h="$PITHEAD_SUPPORT_MAX_HOURS"
    [ "$h" -lt 1 ] && h="$PITHEAD_SUPPORT_DEFAULT_HOURS"
    [ "$h" -gt "$PITHEAD_SUPPORT_MAX_HOURS" ] && h="$PITHEAD_SUPPORT_MAX_HOURS"
    printf '%s' "$h"
}

bundle_support_collect() {
    local outdir="$1" hours="$2" ts out tmp unit db total rc=0
    local unit_cap="${PITHEAD_SUPPORT_MAX_BYTES_PER_UNIT:-2097152}"
    local total_cap="${PITHEAD_SUPPORT_MAX_TOTAL_BYTES:-67108864}"
    mkdir -p "$outdir" || return 1
    chmod 700 "$outdir" 2>/dev/null || true
    ts=$(date -u +%Y%m%dT%H%M%SZ)
    out="$outdir/support-bundle-$ts.tar.gz"
    tmp=$(mktemp -d "$outdir/.support.XXXXXXXX") || return 1
    trap 'rm -rf "$tmp"; exit 130' INT TERM HUP
    mkdir -p "$tmp/bundle/logs"

    {
        echo "window_hours=$hours"
        echo "window_start=$(date -u -d "$hours hours ago" +%FT%TZ 2>/dev/null || date -u +%FT%TZ)"
        echo "collected=$(date -u +%FT%TZ)"
        echo "pithead ${PITHEAD_VERSION:-unknown}"
        uname -a
        echo
        [ -r /etc/os-release ] && cat /etc/os-release
        echo
        df -h / /data 2>/dev/null
        echo
        free -h 2>/dev/null
    } >"$tmp/bundle/host.txt" 2>&1

    if command -v journalctl >/dev/null 2>&1; then
        for unit in $PITHEAD_SUPPORT_UNITS; do
            journalctl -u "$unit" --since "$hours hours ago" --no-pager 2>/dev/null |
                bundle_redact_log | tail -c "$unit_cap" >"$tmp/bundle/logs/$unit.log" || true
        done
        grep -Ei 'bootstrap|circuit' "$tmp/bundle/logs/tor.service.log" >"$tmp/bundle/tor.txt" 2>/dev/null ||
            printf 'no tor bootstrap or circuit lines in the window\n' >"$tmp/bundle/tor.txt"
    else
        printf 'journalctl not present — no journal entries collected\n' >"$tmp/bundle/journal.txt"
    fi

    {
        if command -v rauc >/dev/null 2>&1; then
            rauc status 2>/dev/null | bundle_redact_log || echo "rauc status failed"
        else
            echo "rauc not present"
        fi
    } >"$tmp/bundle/rauc.txt" 2>&1

    if [ -n "${CONFIG_FILE:-}" ] && [ -f "$CONFIG_FILE" ]; then
        render_masked_config "$tmp/scratch" >/dev/null 2>&1 || true
        if [ -f "$tmp/scratch/masked/config.json" ]; then
            bundle_mask_config <"$tmp/scratch/masked/config.json" |
                jq 'def j: if type=="object" then with_entries(.value |= j) elif type=="array" then map(j) else null end; j' \
                    >"$tmp/bundle/config.shape.json" 2>/dev/null || true
        fi
    fi

    db="${DASHBOARD_DATA_DIR:-}/mining_data.db"
    [ -f "$db" ] || db="/data/pithead/dashboard/mining_data.db"
    [ -f "$db" ] || db="/data/mining_data.db"
    if command -v python3 >/dev/null 2>&1 && [ -f "$db" ]; then
        PITHEAD_SUPPORT_DB="$db" PITHEAD_SUPPORT_HOURS="$hours" python3 -I -c '
import json, os, sqlite3, sys, time
db = os.environ["PITHEAD_SUPPORT_DB"]
since = time.time() - float(os.environ["PITHEAD_SUPPORT_HOURS"]) * 3600
try:
    conn = sqlite3.connect("file:%s?mode=ro" % db, uri=True)
    conn.row_factory = sqlite3.Row
    out = {}
    for table, tcol, cols in (
        ("history", "timestamp", "timestamp, v, v_p2pool, v_xvb"),
        ("events", "ts", "ts, type, detail"),
    ):
        try:
            rows = conn.execute(
                "SELECT %s FROM (SELECT %s FROM %s WHERE %s >= ? ORDER BY %s DESC LIMIT 5000) ORDER BY %s ASC"
                % (cols, cols, table, tcol, tcol, tcol),
                (since,),
            ).fetchall()
            out[table] = [dict(r) for r in rows]
        except sqlite3.Error:
            out[table] = None
    print(json.dumps(out))
except sqlite3.Error:
    sys.exit(1)
' 2>/dev/null | bundle_redact_log >"$tmp/bundle/dashboard.history.json" || true
    fi

    total=$(du -sk "$tmp/bundle" 2>/dev/null | awk '{print $1 * 1024}')
    [ -n "$total" ] || total=0
    if [ "$total" -gt "$total_cap" ]; then
        rm -rf "$tmp"
        trap - INT TERM HUP
        return 1
    fi

    (umask 077 && tar -czf "$tmp/bundle.tar.gz" -C "$tmp" bundle) || rc=$?
    [ "$rc" -eq 0 ] && chmod 600 "$tmp/bundle.tar.gz" && mv -f "$tmp/bundle.tar.gz" "$out" || rc=1
    rm -rf "$tmp"
    trap - INT TERM HUP
    [ "$rc" -eq 0 ] || return 1
    printf '%s\n' "$out"
}

recovery_bundle() {
    local hours="$PITHEAD_SUPPORT_DEFAULT_HOURS" outdir arch
    case "${1:-}" in
    "") ;;
    --hours)
        [ "$#" -le 2 ] || error "Usage: pithead recovery-bundle [--hours N]"
        hours=$(bundle_support_clamp_hours "${2:-}")
        ;;
    *) error "Usage: pithead recovery-bundle [--hours N]" ;;
    esac
    command -v journalctl >/dev/null 2>&1 ||
        error "recovery-bundle needs the appliance journal. On a host with a container engine use: $0 support-bundle"
    outdir="${PITHEAD_RECOVERY_BUNDLE_DIR:-/data/pithead/support-bundles}"
    arch=$(bundle_support_collect "$outdir" "$hours") ||
        error "Could not collect a support bundle — nothing was written."
    log "Support bundle written: $arch"
}
