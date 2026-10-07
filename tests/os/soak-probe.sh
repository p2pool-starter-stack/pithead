#!/usr/bin/env bash
# The 7-day unattended soak's daily probe (#1652). Runs on the build host, never on the box, and
# reads the box over ONE non-interactive SSH session whose remote command is fixed below, so a
# reader can audit exactly what the only permitted login did. It appends one line per run to
# LOGDIR/soak.log, labelled `read=N` by the line number it lands on (the one label no two reads
# can share; `day=` is information, and the first cron read lands under 24 h after --start, so it
# shares day=0 with the baseline line), keeps each run's raw readings in LOGDIR/readN.env, and
# scores the run against the day-0 baseline in LOGDIR/day0.env, which ONLY --start writes: a
# cron read never touches it, so a restart in the window's first hours can never be absorbed
# into the baseline it is scored against. The pass condition is the one ruled on #1652 — a
# missing measurement is a FAIL, never a skip.
#
#   tests/os/soak-probe.sh HOST LOGDIR --start     # day 0: write the baseline, open the window
#   tests/os/soak-probe.sh HOST LOGDIR             # every later day (a cron line on the build host)
#   tests/os/soak-probe.sh --self-test             # the verdict over canned readings, no box
#
#   0 6 * * *  $HOME/dev/<worktree>/tests/os/soak-probe.sh <ipv4> $HOME/soak-1652 >>$HOME/soak-1652/cron.log 2>&1
#
# The rules, and the instrument each one reads (#1659 made plain `journalctl -b` unusable on the
# bench for the whole boot, so nothing here depends on it):
#   1 one boot        — /proc/stat btime equals day 0's; the journal-directory count is the
#                       secondary counter (one directory per boot until #1659 lands).
#   2 restarts flat   — every container's RestartCount equals day 0's, AND its StartedAt is day
#                       0's: a supervisor restart moves the first, a hand `podman stop/start`
#                       moves only the second.
#   3 all running     — every day-0 container is `running`; health asserted for all EXCEPT
#                       xmrig-proxy, whose healthcheck is the product defect #1098 (excluded BY
#                       NAME; it must still be running with rules 1-2 holding). The set is DAY 0's:
#                       a container that appears later is outside rule 3 by decision — rule 4
#                       covers the only route by which one could be started.
#   4 no intervention — `journalctl -m -u ssh` counts EXACTLY ONE `Accepted` since the previous
#                       probe's read: this probe's own login. The count starts at the journal
#                       CURSOR the previous read recorded (LOGDIR/ssh.cursor, passed to the remote
#                       command as its one named input), so there is no window edge to straddle
#                       and no clock on either side to trust. With no cursor (day 0, or the file
#                       missing) it falls back to the last 25 h and the line says `window=25h`, so
#                       day 0's line carries a rule-4 FAIL from the setup logins: it is the
#                       baseline, not a soak day. A count of 0 FAILS naming the instrument
#                       (`ssh-journal-blind`): the probe's own login is a positive control the
#                       reading must hold, so 0 means the journal could not be read (cursor
#                       journal split, journald down) — never a quiet day. A cursor names one
#                       entry in one journal file, and a cursor that no longer resolves (journal
#                       vacuumed or reset, box re-flashed) is loud either way, measured both ways
#                       on 2026-09-03: the build host's journalctl refuses the seek (count 0,
#                       `ssh-journal-blind`), the box's seeks to the START and counts every login
#                       on record (457) — a day that fails rule 1 as well, which is the right
#                       answer for it. The read then records a fresh cursor, so the next day
#                       scores normally. journald
#                       writes asynchronously, so a 0 or a 2 on a live box is a rare LOUD flake
#                       to look at, not a silent pass. `last` shows no interactive session; rule
#                       2's StartedAt covers hand-run container verbs. `last` is recorded because
#                       the ruling names it, and it is a NULL instrument on the bench (no wtmp: it
#                       read 0 with 22 logins in the journal) — the journal count is the one that
#                       fires.
#   5 chain recorded  — monerod height / synchronized / peers are RECORDED (a stall is visible)
#                       and never gate. The appliance's monerod RPC is RESTRICTED (measured
#                       2026-09-03: `get_info` answers `restricted:true`, `get_connections` is
#                       "Method not found"), and a restricted `get_info` zeroes the peer counts
#                       and peer lists by design — so peers reads `restricted` there rather than
#                       a 0/0 that is the instrument, not the node; height moving between days is
#                       the stall signal. Tari height, resources and accepted work are also recorded, never gating.
#   6 firewall stable — the stateless egress table hash must match day 0; missing reads FAIL.
# A day whose line is missing, or whose SSH read failed, is a FAIL by the ruling's own terms; a
# failed read keeps the previous cursor, so the next good day also counts the failed day's login.
# Recorded UTC dates detect missed daily invocations; same-day retries retain that date's gap.
# The session skips host-key checking on purpose: the box regenerates its host key on every
# provisioning (#1659's churn) and the probe is read-only on a bench LAN, so a pinned key would
# only turn each re-flash into a READ-FAILED day.
set -uo pipefail

KEY="${PITHEAD_SOAK_KEY:-$HOME/.ssh/pithead-os-test}"
EXCLUDED_HEALTH="xmrig-proxy"

# shellcheck source=tests/os/soak-record.sh
source "$(dirname "$0")/soak-record.sh"

# The one remote command. Read-only by construction: every line is a read, and the .env is
# consulted for monerod's RPC credentials without ever printing them.
read_box() { # $1 = host, $2 = previous read's journal cursor or empty; prints key=value lines
    soak_local timeout 180 ssh -i "$KEY" -o BatchMode=yes -o ConnectTimeout=15 -o StrictHostKeyChecking=no \
        -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR "root@$1" "SOAK_CURSOR='$2' bash -s" <"$(dirname "$0")/soak-read.sh"
}

# Pure over the readings: $1 = day-0 baseline (key=value lines), $2 = today's readings. Prints
# `VERDICT=PASS|FAIL fails=<rule list>` on stdout; exit 0 on PASS. Every rule that cannot be
# measured today FAILS, so an empty reading can never pass.
soak_day_verdict() {
    local base="$1" today="$2" fails="" b t
    rd() { printf '%s\n' "$1" | sed -n "s/^$2=//p" | head -1; } # a reading, not the top-level kv
    b=$(rd "$base" btime)
    t=$(rd "$today" btime)
    { [ -n "$b" ] && [ "$b" = "$t" ]; } || fails="$fails 1:boot(btime $b->${t:-?})"
    b=$(rd "$base" jdirs)
    t=$(rd "$today" jdirs)
    { [ -n "$t" ] && [ "${t:-0}" -le "${b:-0}" ]; } 2>/dev/null || fails="$fails 1:journal-dirs($b->${t:-?})"
    b=$(rd "$base" firewall_hash)
    t=$(rd "$today" firewall_hash)
    if [ "$(rd "$today" firewall_present)" != 1 ] ||
        [[ ! "$b" =~ ^[a-f0-9]{64}$ || ! "$t" =~ ^[a-f0-9]{64}$ ]] || [ "$b" != "$t" ]; then
        fails="$fails 6:firewall-missing-or-changed"
    fi
    local name brc bstarted tstate trc thealth tstarted tline
    while IFS='|' read -r name _ brc _ bstarted; do
        [ -n "$name" ] || continue
        tline=$(printf '%s\n' "$today" | sed -n "s/^container=$name|//p" | head -1)
        if [ -z "$tline" ]; then
            fails="$fails 3:$name-missing"
            continue
        fi
        IFS='|' read -r tstate trc thealth tstarted <<<"$tline"
        [ "$tstate" = running ] || fails="$fails 3:$name-$tstate"
        [ "$trc" = "$brc" ] || fails="$fails 2:$name-restarts($brc->$trc)"
        [ "$tstarted" = "$bstarted" ] || fails="$fails 2:$name-started-anew"
        if [ "$name" != "$EXCLUDED_HEALTH" ] && [ "$thealth" != none ] && [ "$thealth" != healthy ]; then fails="$fails 3:$name-$thealth"; fi
    done < <(printf '%s\n' "$base" | sed -n 's/^container=//p')
    t=$(rd "$today" ssh_accepted)
    case "$t" in
    '' | *[!0-9]*) fails="$fails 4:ssh-accepted(${t:-?})" ;;
    0) fails="$fails 4:ssh-journal-blind(0)" ;; # the probe's own login is missing: the instrument, not the day
    1) ;;
    *) fails="$fails 4:ssh-accepted($t)" ;;
    esac
    t=$(rd "$today" last_sessions)
    { [ -n "$t" ] && [ "$t" -eq 0 ]; } 2>/dev/null || fails="$fails 4:last-sessions(${t:-?})"
    if [ -z "$fails" ]; then
        echo "VERDICT=PASS"
        return 0
    fi
    echo "VERDICT=FAIL fails=${fails# }"
    return 1
}

self_test() {
    local base today out
    # Collector functions normally run under GNU tools on the Linux guest. Here only,
    # bound their stubbed commands with the workstation helper instead.
    timeout() { soak_local timeout "$@"; }
    base=$'btime=100\njdirs=1\ncontainer=monerod|running|0|healthy|2026-09-03T06:00:00Z\ncontainer=xmrig-proxy|running|0|unhealthy|2026-09-03T06:00:00Z\nssh_window=cursor\nssh_accepted=1\nlast_sessions=0\nmonero=h:100 sync:true peers:1/2'
    base+=$'\nfirewall_present=1\nfirst_sync_exemption=0\nfirewall_hash='
    base+=$(printf steady | soak_local sha256)
    base+=$'\nfirewall_listing_b64=e30K'
    n=0
    f=0
    chk() { if [ "$2" = "$3" ]; then n=$((n + 1)); else
        f=$((f + 1))
        echo "  ✗ $1: [$2] wanted [$3]"
    fi; }
    out=$(soak_day_verdict "$base" "$base")
    chk "identical day passes (xmrig-proxy unhealthy is excluded by name)" "$?" 0
    today=${base/btime=100/btime=200}
    out=$(soak_day_verdict "$base" "$today")
    chk "a new btime fails rule 1" "$?" 1
    chk "  …named" "${out#*fails=}" "1:boot(btime 100->200)"
    today=${base/jdirs=1/jdirs=2}
    out=$(soak_day_verdict "$base" "$today")
    chk "a new journal directory fails rule 1" "$?" 1
    today=${base/monerod|running|0|healthy/monerod|running|1|healthy}
    out=$(soak_day_verdict "$base" "$today")
    chk "a supervisor restart fails rule 2" "$?" 1
    chk "  …named" "${out#*fails=}" "2:monerod-restarts(0->1)"
    today=${base/monerod|running|0|healthy|2026-09-03T06:00:00Z/monerod|running|0|healthy|2026-09-04T06:00:00Z}
    out=$(soak_day_verdict "$base" "$today")
    chk "a hand stop/start (StartedAt moved, RestartCount not) fails rule 2" "$?" 1
    today=${base/monerod|running|0|healthy/monerod|exited|0|none}
    out=$(soak_day_verdict "$base" "$today")
    chk "a container not running fails rule 3" "$?" 1
    today=${base/monerod|running|0|healthy/monerod|running|0|unhealthy}
    out=$(soak_day_verdict "$base" "$today")
    chk "monerod unhealthy fails rule 3 (only xmrig-proxy is excluded)" "$?" 1
    today=${base/xmrig-proxy|running|0|unhealthy/xmrig-proxy|exited|0|unhealthy}
    out=$(soak_day_verdict "$base" "$today")
    chk "xmrig-proxy NOT running still fails rule 3 (the exclusion is health only)" "$?" 1
    today=$(printf '%s\n' "$base" | grep -v '^container=monerod')
    out=$(soak_day_verdict "$base" "$today")
    chk "a day-0 container missing from today fails rule 3" "$?" 1
    today=${base/ssh_accepted=1/ssh_accepted=2}
    out=$(soak_day_verdict "$base" "$today")
    chk "a second SSH login fails rule 4" "$?" 1
    chk "  …named" "${out#*fails=}" "4:ssh-accepted(2)"
    today=${base/ssh_accepted=1/ssh_accepted=0}
    out=$(soak_day_verdict "$base" "$today")
    chk "zero logins fails rule 4 naming the instrument (the probe's own login is the positive control)" "$?" 1
    chk "  …named" "${out#*fails=}" "4:ssh-journal-blind(0)"
    today=$(printf '%s\n' "$base" | grep -v '^ssh_accepted=')
    out=$(soak_day_verdict "$base" "$today")
    chk "no ssh reading at all fails rule 4" "$?" 1
    chk "  …named" "${out#*fails=}" "4:ssh-accepted(?)"
    today=${base/monero=h:100 sync:true peers:1\/2/monero=h:50 sync:false peers:0\/0}
    out=$(soak_day_verdict "$base" "$today")
    chk "a changed chain reading still passes (rule 5 records, never gates)" "$?" 0
    today=${base/last_sessions=0/last_sessions=1}
    out=$(soak_day_verdict "$base" "$today")
    chk "an interactive session fails rule 4" "$?" 1
    out=$(soak_day_verdict "$base" "")
    chk "an empty reading FAILS every rule, never passes" "$?" 1
    self_test_driver "$base"
    # shellcheck source=tests/os/soak-selftest.sh
    source "$(dirname "$0")/soak-selftest.sh"
    soak_extended_selftest "$base"
    echo "soak-probe self-test: $n ok, $f failed"
    [ "$f" -eq 0 ]
}

# The driver, through a stubbed `ssh` that prints a canned reading: the pure verdict above cannot
# see what the driver does with LOGDIR, and that is where the first cron read used to overwrite
# day0.env and every later day passed against the moved baseline (#1667 F1). Three runs land in
# the same day=0, which is the shape the label and the write-once baseline exist for.
self_test_driver() { # $1 = a canned reading that passes against itself
    local tmp out
    # A scratch dir that cannot be made is a FAILED row, never a skipped set: bare `return` here
    # dropped the nine driver rows and the summary still read `0 failed`, rc 0 (#1670).
    tmp=$(mktemp -d) || {
        chk "driver: mktemp -d" 1 0
        return
    }
    mkdir -p "$tmp/bin"
    printf '%s\n' '#!/usr/bin/env bash' 'cat >/dev/null' 'printf "%s\n" "${@: -1}" >>"$SOAK_STUB_ARGS"' 'cat "$SOAK_STUB_READING"' >"$tmp/bin/ssh"
    chmod +x "$tmp/bin/ssh"
    printf '%s\nssh_cursor=s=1;i=1\n' "$1" >"$tmp/a"
    printf '%s\nssh_cursor=s=2;i=2\n' "${1/monerod|running|0|healthy/monerod|running|1|healthy}" >"$tmp/b"
    drv() { PATH="$tmp/bin:$PATH" SOAK_STUB_READING="$tmp/$1" SOAK_STUB_ARGS="$tmp/args" bash "$0" stub-host "$tmp/log" ${2:-}; }
    drv a --start >/dev/null
    chk "driver: --start passes against its own reading" "$?" 0
    cmp -s "$tmp/a" "$tmp/log/day0.env"
    chk "driver: day0.env is the --start reading" "$?" 0
    drv b >/dev/null
    chk "driver: a restart on the first cron read (still day=0) fails rule 2" "$?" 1
    cmp -s "$tmp/a" "$tmp/log/day0.env"
    chk "driver: day0.env is byte-identical after that read (write-once)" "$?" 0
    out=$(drv b)
    chk "driver: the same reading again STILL fails — the baseline never absorbed the restart" "$?" 1
    chk "  …named" "${out##*fails=}" "2:monerod-restarts(0->1)"
    chk "driver: three lines, three distinct read= labels" "$(sed -n 's/^[^ ]* read=\([0-9]*\) .*/\1/p' "$tmp/log/soak.log" | sort -u | tr '\n' ' ')" "1 2 3 "
    sed '/^mem_used_kib=/,$d' "$tmp/log/read3.env" >"$tmp/raw"
    cmp -s "$tmp/b" "$tmp/raw"
    chk "driver: read3.env holds the third read's raw readings" "$?" 0
    chk "driver: the second read was handed the first read's cursor" "$(sed -n 2p "$tmp/args")" "SOAK_CURSOR='s=1;i=1' bash -s"
    rm -rf "$tmp"
}

case "${1:-}" in
--self-test)
    self_test
    exit $?
    ;;
'' | -h | --help)
    awk 'NR > 1 && /^set -/ { exit } NR > 1 { sub(/^# ?/, ""); print }' "$0"
    exit 2
    ;;
esac
if [ -z "${2:-}" ]; then # HOST without LOGDIR would mkdir "" and write day0.env at /
    echo "usage: $0 HOST LOGDIR [--start|--read] | --self-test" >&2
    exit 2
fi
HOST="$1"
LOGDIR="$2"
MODE="${3:-}"
case "$MODE" in '' | --start | --read) ;; *)
    echo "unknown mode: $MODE" >&2
    exit 2
    ;;
esac
umask 077
mkdir -p "$LOGDIR"
chmod 700 "$LOGDIR"
sample_epoch=$(date -u +%s)
now=$(soak_local utc "$sample_epoch")
soak_record_schedule
# This run's label is the soak.log line number it lands on — day= is information, not identity.
line=$(($([ -f "$LOGDIR/soak.log" ] && wc -l <"$LOGDIR/soak.log" || echo 0) + 1))
# The previous read's journal cursor is the one input the fixed remote command takes. --start
# opens a new window and ignores any cursor a previous window left behind.
cursor=""
if [ "$MODE" != "--start" ] && [ -s "$LOGDIR/ssh.cursor" ]; then
    cursor=$(head -1 "$LOGDIR/ssh.cursor")
    case "$cursor" in *[!A-Za-z0-9\;=]*) cursor="" ;; esac # anything else never came from journalctl
fi
today=$(read_box "$HOST" "$cursor")
rc=$?
if [ "$rc" -ne 0 ] || [ -z "$today" ]; then
    printf '%s read=%s day=? READ-FAILED ssh rc=%s sample_epoch=%s missing_days=%s VERDICT=FAIL fails=read\n' "$now" "$line" "$rc" "$sample_epoch" "$missing_days" | tee -a "$LOGDIR/soak.log"
    exit 1
fi
kv() { printf '%s\n' "$today" | sed -n "s/^$1=//p" | head -1; }
if [ "$MODE" = "--read" ]; then
    printf '%s\n' "$today" >"$LOGDIR/read.env"
    printf '%s\n' "$(kv firewall_listing_b64)" | soak_local decode >"$LOGDIR/read.firewall.json"
    echo "Read-only collection saved; no soak window opened."
    exit 0
fi
if [ "$MODE" = "--start" ] && { [ "$(kv first_sync_exemption)" != 0 ] ||
    [ "$(kv firewall_present)" != 1 ] || [[ ! "$(kv firewall_hash)" =~ ^[a-f0-9]{64}$ ]]; }; then
    echo "REFUSED: day 0 needs a readable egress table with no first-sync clearnet exemption." >&2
    printf '%s\n' "$today" >"$LOGDIR/refused-start.env"
    exit 1
fi
if [ "$MODE" = "--start" ]; then # the ONLY writer of day0.env
    printf '%s\n' "$(kv firewall_listing_b64)" | soak_local decode >"$LOGDIR/day0.firewall.json"
    printf '%s\n' "$today" >"$LOGDIR/day0.env"
    printf '%s\n' "$now" >"$LOGDIR/started"
fi
[ -s "$LOGDIR/day0.env" ] || {
    printf '%s read=%s day=? NO-BASELINE VERDICT=FAIL fails=baseline (run with --start first)\n' "$now" "$line" | tee -a "$LOGDIR/soak.log"
    exit 1
}
day='?'
if started_epoch=$(soak_local epoch "$(cat "$LOGDIR/started")" 2>/dev/null); then
    day=$(((sample_epoch - started_epoch) / 86400))
else
    missing_days='?'
fi
running=$(printf '%s\n' "$today" | grep -c '^container=.*|running|')
total=$(printf '%s\n' "$today" | grep -c '^container=')
unhealthy=$(printf '%s\n' "$today" | sed -n 's/^container=\([^|]*\)|[^|]*|[^|]*|unhealthy|.*/\1/p' | tr '\n' ',' | sed 's/,$//')
soak_record_derived
verdict=$(soak_day_verdict "$(cat "$LOGDIR/day0.env")" "$today")
if [ "$missing_days" != 0 ]; then
    case "$verdict" in
    VERDICT=PASS*) verdict="VERDICT=FAIL fails=schedule:missing-days($missing_days)" ;;
    *) verdict+=" schedule:missing-days($missing_days)" ;;
    esac
fi
if [[ "$verdict" == *6:firewall* ]]; then
    cp "$LOGDIR/day0.firewall.json" "$LOGDIR/read$line.firewall-baseline.json"
    printf '%s\n' "$(kv firewall_listing_b64)" | soak_local decode >"$LOGDIR/read$line.firewall-current.json"
fi
printf '%s read=%s day=%s btime=%s jdirs=%s up=%ss running=%s/%s unhealthy=%s ssh_accepted=%s window=%s last=%s monero=%s rauc=%s data_free_mb=%s load=%s %s %s\n' \
    "$now" "$line" "$day" "$(kv btime)" "$(kv jdirs)" "$(kv uptime_s)" "$running" "$total" "${unhealthy:-none}" "$(kv ssh_accepted)" "$(kv ssh_window)" "$(kv last_sessions)" "$(kv monero)" "$(kv rauc)" "$(kv data_free_mb)" "$(kv load)" "$(soak_record_summary)" "$verdict" |
    tee -a "$LOGDIR/soak.log"
printf '%s\n' "$today" >"$LOGDIR/read$line.env"
[ -n "$(kv ssh_cursor)" ] && printf '%s\n' "$(kv ssh_cursor)" >"$LOGDIR/ssh.cursor"
case "$verdict" in VERDICT=PASS*) exit 0 ;; *) exit 1 ;; esac
