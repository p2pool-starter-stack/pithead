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

bundle_support_window() {
    PITHEAD_WIN_SINCE="$1" PITHEAD_WIN_UNTIL="$2" PITHEAD_WIN_HOURS="$3" python3 -I -c '
import os, re, sys
from datetime import datetime, timedelta, timezone

RFC3339 = re.compile(r"^(\d{4}-\d\d-\d\dT\d\d:\d\d:\d\d)(\.\d+)?(Z|z|[+-]\d\d:\d\d)$")


def parse(name, value):
    m = RFC3339.match(value.strip())
    if not m:
        sys.exit("%s %r is not an RFC 3339 time such as 2026-11-15T10:00:00Z" % (name, value))
    zone = "+00:00" if m.group(3) in "Zz" else m.group(3)
    frac = "." + (m.group(2) or ".")[1:].ljust(6, "0")[:6]
    try:
        return datetime.fromisoformat(m.group(1) + frac + zone).astimezone(timezone.utc)
    except ValueError:
        sys.exit("%s %r is not a valid time" % (name, value))


now = datetime.now(timezone.utc).replace(microsecond=0)
raw_since, raw_until = os.environ["PITHEAD_WIN_SINCE"], os.environ["PITHEAD_WIN_UNTIL"]
hours = int(os.environ["PITHEAD_WIN_HOURS"])
until = parse("end time", raw_until) if raw_until else now
if until > now:
    sys.exit("end time %s is in the future" % until.strftime("%Y-%m-%dT%H:%M:%SZ"))
since = parse("start time", raw_since) if raw_since else until - timedelta(hours=hours)
if since > until:
    sys.exit("start time %s is after end time %s" % (since.strftime("%Y-%m-%dT%H:%M:%SZ"), until.strftime("%Y-%m-%dT%H:%M:%SZ")))
print(since.strftime("%Y-%m-%dT%H:%M:%SZ"), until.strftime("%Y-%m-%dT%H:%M:%SZ"))
'
}

bundle_support_step_fail() {
    local tmp="$1" step="$2" kind="$3" why
    why=$(printf '%s' "$4" | bundle_redact_log | tr '\t\n' '  ' | cut -c1-200)
    printf '%s\t%s\t%s\n' "$step" "$kind" "$why" >>"$tmp/steps.tsv"
}

bundle_support_capture() {
    local tmp="$1" rel="$2" cap="$3" installed="$4" short="$5" since="$6" until="$7" prc
    shift 7
    local meta="$tmp/meta/${rel//\//__}.json" err="$tmp/err" runner=()
    command -v timeout >/dev/null 2>&1 && runner=(timeout "${PITHEAD_SUPPORT_STEP_TIMEOUT:-300}")
    mkdir -p "$tmp/bundle/$(dirname "$rel")" "$tmp/meta"
    "${runner[@]}" "$@" 2>"$err" </dev/null | bundle_redact_log |
        python3 -I "$tmp/cap.py" "$tmp/bundle/$rel" "$cap" "$meta" "$installed" "$short" "$since" "$until" &&
        prc=(0 0 0) || prc=("${PIPESTATUS[@]}")
    if [ "${prc[0]}" -eq 124 ]; then
        bundle_support_step_fail "$tmp" "$rel" timeout "timed out after ${PITHEAD_SUPPORT_STEP_TIMEOUT:-300}s"
    elif [ "${prc[0]}" -ne 0 ]; then
        bundle_support_step_fail "$tmp" "$rel" failed "exit ${prc[0]}: $(head -n1 "$err" 2>/dev/null)"
    fi
    [ "${prc[1]}" -eq 0 ] && [ "${prc[2]}" -eq 0 ] || return 1
}

bundle_support_jtime() {
    local t="${1%Z}"
    printf '%s UTC' "${t/T/ }"
}

bundle_support_units() {
    local installed unit flat
    installed=$( (systemctl list-unit-files --type=service --type=timer --no-legend --no-pager 2>/dev/null || true) |
        awk '$1 ~ /^pithead/ || $2 == "generated" {print $1}' | sort -u)
    flat=" ${installed//$'\n'/ } "
    for unit in $installed; do printf '%s 1\n' "$unit"; done
    for unit in $PITHEAD_SUPPORT_UNITS; do
        case "$flat" in *" $unit "*) ;; *) printf '%s 0\n' "$unit" ;; esac
    done
}

bundle_support_collect() {
    local outdir="$1" since="$2" until="$3" ts out tmp unit installed db rc=0
    local file_cap="${PITHEAD_SUPPORT_MAX_BYTES_PER_FILE:-16777216}"
    local total_cap="${PITHEAD_SUPPORT_MAX_TOTAL_BYTES:-67108864}"
    local eff_since="$since" short=0 oldest_epoch="" oldest_iso="" since_epoch until_epoch jsince juntil
    mkdir -p "$outdir" || return 1
    chmod 700 "$outdir" 2>/dev/null || true
    ts=$(date -u +%Y%m%dT%H%M%SZ)
    out="$outdir/support-bundle-$ts.zip"
    tmp=$(mktemp -d "$outdir/.support.XXXXXXXX") || return 1
    trap 'rm -rf "$tmp"; exit 130' INT TERM HUP
    mkdir -p "$tmp/bundle/logs" "$tmp/bundle/journal" "$tmp/meta"
    bundle_support_cap_py >"$tmp/cap.py"
    bundle_support_pack_py >"$tmp/pack.py"
    : >"$tmp/steps.tsv"
    since_epoch=$(date -u -d "$since" +%s 2>/dev/null) || since_epoch=0
    until_epoch=$(date -u -d "$until" +%s 2>/dev/null) || until_epoch=0

    local jd="" jcfg=""
    if command -v journalctl >/dev/null 2>&1; then
        oldest_epoch=$( (journalctl -o short-unix --no-pager -q 2>/dev/null || true) | head -n1 | cut -d' ' -f1)
        oldest_epoch=${oldest_epoch%%.*}
        case "$oldest_epoch" in '' | *[!0-9]*) oldest_epoch="" ;; esac
        if [ -n "$oldest_epoch" ]; then
            oldest_iso=$(date -u -d "@$oldest_epoch" +%Y-%m-%dT%H:%M:%SZ)
            if [ "$oldest_epoch" -gt "$since_epoch" ]; then
                short=1
                eff_since="$oldest_iso"
                [ "$oldest_epoch" -gt "$until_epoch" ] && eff_since="$until"
            fi
        fi
        jd=$(journalctl --disk-usage 2>&1 | bundle_redact_log | head -n1 || true)
    fi
    jcfg=$( (systemd-analyze cat-config systemd/journald.conf 2>/dev/null ||
        cat /etc/systemd/journald.conf /etc/systemd/journald.conf.d/*.conf 2>/dev/null || true) |
        grep -vE '^[[:space:]]*(#|;|$)' | bundle_redact_log || true)
    jsince=$(bundle_support_jtime "$eff_since")
    juntil=$(bundle_support_jtime "$until")

    {
        echo "window_requested=$since/$until"
        echo "window_effective=$eff_since/$until"
        echo "collected=$(date -u +%FT%TZ)"
        echo "pithead ${PITHEAD_VERSION:-unknown}"
        uname -a
        echo
        [ -r /etc/os-release ] && cat /etc/os-release
        echo
        df -h / /data 2>/dev/null
        echo
        free -h 2>/dev/null
    } 2>&1 | bundle_redact_log >"$tmp/bundle/host.txt"

    if command -v journalctl >/dev/null 2>&1; then
        local jargs=(--since "$jsince" --until "$juntil" --no-pager --utc)
        bundle_support_capture "$tmp" journal/all.log "$file_cap" 1 "$short" "$eff_since" "$until" \
            journalctl "${jargs[@]}" || true
        bundle_support_capture "$tmp" journal/kernel.log "$file_cap" 1 "$short" "$eff_since" "$until" \
            journalctl -k "${jargs[@]}" || true
        bundle_support_capture "$tmp" journal/boots.txt "$file_cap" 1 0 "$eff_since" "$until" \
            journalctl --list-boots --no-pager || true
        while read -r unit installed; do
            [ -n "$unit" ] || continue
            bundle_support_capture "$tmp" "logs/$unit.log" "$file_cap" "$installed" "$short" "$eff_since" "$until" \
                journalctl -u "$unit" "${jargs[@]}" || true
        done < <(bundle_support_units)
        grep -Ei 'bootstrap|circuit' "$tmp/bundle/logs/tor.service.log" >"$tmp/bundle/tor.txt" 2>/dev/null ||
            printf 'no tor bootstrap or circuit lines in the window\n' >"$tmp/bundle/tor.txt"
    else
        printf 'journalctl not present — no journal entries collected\n' >"$tmp/bundle/journal.txt"
        bundle_support_step_fail "$tmp" journal failed "journalctl not present"
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
                jq 'def j: if type=="object" then with_entries(.value |= j) elif type=="array" then map(j) else null end; j' 2>/dev/null |
                bundle_redact_log >"$tmp/bundle/config.shape.json" || true
        fi
    fi

    db="${DASHBOARD_DATA_DIR:-}/mining_data.db"
    [ -f "$db" ] || db="/data/pithead/dashboard/mining_data.db"
    [ -f "$db" ] || db="/data/mining_data.db"
    if command -v python3 >/dev/null 2>&1 && [ -f "$db" ]; then
        PITHEAD_SUPPORT_DB="$db" PITHEAD_SUPPORT_SINCE="$since_epoch" PITHEAD_SUPPORT_UNTIL="$until_epoch" python3 -I -c '
import json, os, sqlite3, sys
db = os.environ["PITHEAD_SUPPORT_DB"]
since = float(os.environ["PITHEAD_SUPPORT_SINCE"])
until = float(os.environ["PITHEAD_SUPPORT_UNTIL"])
try:
    conn = sqlite3.connect("file:%s?mode=ro" % db, uri=True)
    conn.row_factory = sqlite3.Row
    out = {"row_limit_per_table": 5000}
    for table, tcol, cols in (
        ("history", "timestamp", "timestamp, v, v_p2pool, v_xvb"),
        ("events", "ts", "ts, type, detail"),
    ):
        try:
            rows = conn.execute(
                "SELECT %s FROM (SELECT %s FROM %s WHERE %s >= ? AND %s <= ? ORDER BY %s DESC LIMIT 5000) ORDER BY %s ASC"
                % (cols, cols, table, tcol, tcol, tcol, tcol),
                (since, until),
            ).fetchall()
            out[table] = [dict(r) for r in rows]
        except sqlite3.Error:
            out[table] = None
    print(json.dumps(out))
except sqlite3.Error:
    sys.exit(1)
' 2>/dev/null | bundle_redact_log >"$tmp/bundle/dashboard.history.json" || true
    fi

    jq -n \
        --arg rs "$since" --arg ru "$until" --arg es "$eff_since" --arg oldest "$oldest_iso" \
        --argjson short "$short" --arg jd "$jd" --arg jcfg "$jcfg" \
        --arg ver "${PITHEAD_VERSION:-unknown}" --arg at "$(date -u +%FT%TZ)" \
        --argjson fcap "$file_cap" --argjson tcap "$total_cap" '{
            manifest_version: 1,
            pithead_version: $ver,
            collected_at: $at,
            window: {
                requested: {since: $rs, until: $ru},
                effective: {since: $es, until: $ru},
                oldest_retained_entry: (if $oldest == "" then null else $oldest end),
                journal_short: ($short == 1)
            },
            journald: {disk_usage: $jd, effective_settings: ($jcfg | split("\n") | map(select(. != "")))},
            size_policy: {
                per_file_cap_bytes: $fcap,
                total_cap_bytes: $tcap,
                keeps: "the oldest quarter and the newest three quarters of each capped file; a marker line names what was dropped"
            }
        }' >"$tmp/info.json" || rc=1
    [ "$rc" -eq 0 ] &&
        PITHEAD_PACK_CAPDIR="$tmp" python3 -I "$tmp/pack.py" "$tmp/bundle" "$tmp/meta" "$tmp/info.json" "$tmp/steps.tsv" "$tmp/bundle.zip" "$total_cap" || rc=1
    [ "$rc" -eq 0 ] && chmod 600 "$tmp/bundle.zip" && mv -f "$tmp/bundle.zip" "$out" || rc=1
    rm -rf "$tmp"
    trap - INT TERM HUP
    [ "$rc" -eq 0 ] || return 1
    printf '%s\n' "$out"
}

recovery_bundle() {
    local hours="" since="" until="" outdir arch win usage="Usage: pithead recovery-bundle [--hours N] [--since TIME] [--until TIME]"
    while [ "$#" -gt 0 ]; do
        [ "$#" -ge 2 ] || error "$usage"
        case "$1" in
        --hours) hours=$(bundle_support_clamp_hours "$2") ;;
        --since) since="$2" ;;
        --until) until="$2" ;;
        *) error "$usage" ;;
        esac
        shift 2
    done
    command -v journalctl >/dev/null 2>&1 ||
        error "recovery-bundle needs the appliance journal. On a host with a container engine use: $0 support-bundle"
    win=$(bundle_support_window "$since" "$until" "${hours:-$PITHEAD_SUPPORT_DEFAULT_HOURS}" 2>&1) || error "$win"
    outdir="${PITHEAD_RECOVERY_BUNDLE_DIR:-/data/pithead/support-bundles}"
    # shellcheck disable=SC2086
    arch=$(bundle_support_collect "$outdir" $win) ||
        error "Could not collect a support bundle — nothing was written."
    log "Support bundle written: $arch"
}
