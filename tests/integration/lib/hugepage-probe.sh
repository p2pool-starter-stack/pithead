# shellcheck shell=bash
#
# HugePages held by monerod and p2pool across a live run (#2685).
#
# The appliance's reduced tier reserves a fixed pool (os/overlay/pithead-hugepages), sized from
# this row's own measured peaks (#2685). This samples what each process actually holds, both to
# take that measurement and to stand guard afterward: a daemon whose RandomX memory fell out of
# the pool altogether turns the run red instead of passing unnoticed. Before #2562 raised
# p2pool's container cap to 4g, that fallback restart-looped it at its 1g mem_limit (the #78
# spike); the cap now holds the fallback, so the modern failure is silent — p2pool keeps running
# on ordinary memory instead of hugetlb, unremarked anywhere else — which is exactly what the
# settle-window check below catches. A daemon that keeps some pages in the pool (p2pool's caches)
# while the rest falls back is not zero, and this row does not catch it. A separate bound (below)
# checks THIS run's combined peak, plus the second-seed caches a run this long may never touch,
# against the appliance's pinned REDUCED_PAGES — the check the resize itself is proved by.
#
# Measured per process from /proc/<pid>/smaps_rollup (Private_Hugetlb + Shared_Hugetlb), never
# from a HugePages_Free delta in /proc/meminfo: the pool is shared with anything else on the box
# that maps large pages (a miner, another stack), and a delta would count their pages as ours.
# The sampler runs for the whole destructive run and keeps every reading, because monerod's
# per-thread verification VMs appear only once it verifies a block; the peak is the maximum.
#
# Sourced by run.sh; the verdict and the artifact are pure functions over the sample file, so
# selftest-hugepage-probe.sh drives them from fixtures.

HUGEPAGE_PROCS="monerod p2pool"
HUGEPAGE_INTERVAL_S=10
# Both daemons allocate their RandomX memory at start: p2pool its dataset and both caches in the
# RandomX_Hasher constructor (src/pow_hash.cpp), monerod its main-seed cache once the chain is
# open. An instance still at zero after this long has fallen back rather than not got there yet.
HUGEPAGE_SETTLE_S=300
# A restart can be read once or twice before its allocation lands; a crash loop is instance
# after instance that never holds a page, each too short-lived for the settle window. This many
# zero-only instances of one daemon in a run is the loop, not a restart.
HUGEPAGE_ZERO_LOOP=3
HUGEPAGE_SAMPLES=""
HUGEPAGE_SAMPLER_PID=""
HUGEPAGE_HOST_THREADS=""

# The bound against the appliance's pinned reduced-tier pool (#2685): this run's combined peak,
# plus one second-seed cache per process (a seed switch is roughly every 2.8 days, so a run this
# long is not guaranteed to see one), must fit REDUCED_PAGES. Read from the checked-out repo's
# own overlay file — the branch under test's, on the bench as everywhere else — rather than
# duplicating the constant here, so the two can never drift apart silently. Overridable so the
# selftest can point it at a fixture.
HUGEPAGE_REDUCED_TIER_FILE="${HUGEPAGE_REDUCED_TIER_FILE:-${BASH_SOURCE[0]%/*}/../../../os/overlay/pithead-hugepages}"
HUGEPAGE_SECOND_SEED_PAGES=256

# One reading per daemon, one TSV line each: epoch, name, pid, starttime, hugetlb kB, threads.
# A daemon not running (or its entrypoint not yet exec'd into it) reads as "-" in every field
# after the name. The pid is the container's init, which both entrypoints exec into; comm
# confirms it before the rollup is read. Another user's rollup needs root, hence sudo -n; a
# running daemon whose rollup cannot be read is "?" in the kB field, never absent.
read -r -d '' HUGEPAGE_SAMPLE_SNIPPET <<'SNIPPET'
now=$(date +%s)
for c in monerod p2pool; do
    pid=$(docker inspect -f '{{.State.Pid}}' "$c" 2>/dev/null) || pid=0
    if [ "${pid:-0}" -gt 0 ] 2>/dev/null && [ "$(cat "/proc/$pid/comm" 2>/dev/null)" = "$c" ]; then
        start=$(awk '{print $22}' "/proc/$pid/stat" 2>/dev/null)
        threads=$(awk '/^Threads:/ {print $2}' "/proc/$pid/status" 2>/dev/null)
        body=$(cat "/proc/$pid/smaps_rollup" 2>/dev/null || sudo -n cat "/proc/$pid/smaps_rollup" 2>/dev/null)
        kb='?'
        [ -z "$body" ] || kb=$(printf '%s\n' "$body" | awk '/^(Private|Shared)_Hugetlb:/ {kb += $2} END {print kb + 0}')
        printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$now" "$c" "$pid" "${start:--}" "$kb" "${threads:--}"
    else
        printf '%s\t%s\t-\t-\t-\t-\n' "$now" "$c"
    fi
done
SNIPPET

hugepage_sample() { rx "$HUGEPAGE_SAMPLE_SNIPPET" 2>/dev/null; }

# Background loop for the life of the run. It stops at its stop file, and polls its parent each
# second so a harness killed mid-run (a cancelled job, a drain) never leaves it behind. It closes
# the rig-lock descriptors it inherited so it can never hold the lock past the harness.
hugepages_sampler_start() { # <samples-file>
    HUGEPAGE_SAMPLES="$1"
    rm -f "$HUGEPAGE_SAMPLES.stop" && : >"$HUGEPAGE_SAMPLES" || return 1
    local parent=$$
    (
        exec 8>&- 9<&-
        while kill -0 "$parent" 2>/dev/null && [ ! -e "$HUGEPAGE_SAMPLES.stop" ]; do
            hugepage_sample >>"$HUGEPAGE_SAMPLES" </dev/null
            for _ in $(seq "$HUGEPAGE_INTERVAL_S"); do
                kill -0 "$parent" 2>/dev/null && [ ! -e "$HUGEPAGE_SAMPLES.stop" ] || exit 0
                sleep 1
            done
        done
    ) &
    HUGEPAGE_SAMPLER_PID=$!
}

# Ask the loop to stop and let a round in flight finish, so nothing lands after the final
# reading; a round stuck past a minute is killed.
hugepages_sampler_stop() {
    [ -n "$HUGEPAGE_SAMPLER_PID" ] || return 0
    : >"$HUGEPAGE_SAMPLES.stop"
    local i=0
    while kill -0 "$HUGEPAGE_SAMPLER_PID" 2>/dev/null && [ "$i" -lt 60 ]; do
        sleep 1
        i=$((i + 1))
    done
    kill "$HUGEPAGE_SAMPLER_PID" 2>/dev/null
    wait "$HUGEPAGE_SAMPLER_PID" 2>/dev/null
    HUGEPAGE_SAMPLER_PID=""
    rm -f "$HUGEPAGE_SAMPLES.stop"
    hugepage_sample >>"$HUGEPAGE_SAMPLES" </dev/null
}

# Pure: per daemon over the sample file, one TSV line each:
#   name  readings  unreadable  peak_kb  peak_threads  settled_zero  zero_only
# readings counts samples that read the daemon's rollup; unreadable, those that found it running
# and could not. An instance is pid + starttime, so a reused pid is a new instance. zero_only
# counts instances that never held a hugetlb page; settled_zero, those of them seen across at
# least <settle_s>.
hugepage_tally() { # <samples-file> <settle_s>
    awk -F'\t' -v settle="$2" -v procs="$HUGEPAGE_PROCS" '
        $3 != "-" && $5 == "?" { bad[$2]++ }
        $3 != "-" && $5 ~ /^[0-9]+$/ {
            n[$2]++
            if ($5 > peak[$2]) peak[$2] = $5
            if ($6 ~ /^[0-9]+$/ && $6 > thr[$2]) thr[$2] = $6
            k = $2 SUBSEP $3 SUBSEP $4
            if (!(k in first)) first[k] = $1
            last[k] = $1
            if ($5 > imax[k]) imax[k] = $5
        }
        END {
            for (k in first) {
                if (imax[k] + 0 > 0) continue
                split(k, p, SUBSEP)
                zero[p[1]]++
                if (last[k] - first[k] >= settle) settled[p[1]]++
            }
            split(procs, names, " ")
            for (i = 1; names[i] != ""; i++) {
                c = names[i]
                printf "%s\t%d\t%d\t%d\t%d\t%d\t%d\n", c, n[c], bad[c], peak[c], thr[c], settled[c], zero[c]
            }
        }' "$1"
}

# Pure: the artifact, from a tally. Pages are 2 MiB pages, the unit REDUCED_PAGES is set in; a
# partial page rounds up.
hugepage_report_json() { # <tally> <interval_s> <settle_s> <samples> <host_threads>
    printf '%s\n' "$1" | jq -R -s \
        --argjson interval "$2" --argjson settle "$3" --argjson samples "$4" --arg host_threads "$5" '
        {interval_s: $interval, settle_s: $settle, sample_rounds: $samples,
         host_threads: ($host_threads | tonumber? // null),
         processes: (split("\n") | map(select(length > 0) | split("\t") | map(tonumber? // .)) | map({key: .[0], value: {
             readings: .[1], unreadable: .[2], peak_kb: .[3], peak_pages: ((.[3] + 2047) / 2048 | floor),
             peak_threads: .[4], settled_zero_instances: .[5], zero_only_instances: .[6]}}) | from_entries)}'
}

# The gate, per daemon. Red when its rollup could never be read while it ran, when it held no
# hugetlb page at any reading, when an instance ran past the settle window without one, or when
# instance after instance never held one (the loop). A daemon this run never saw running is a
# skipped leg, not a pass: the other phases own "it is running", and this row cannot judge it.
hugepage_assert() { # <tally>
    local name readings unreadable peak threads settled zeros
    while IFS=$'\t' read -r name readings unreadable peak threads settled zeros; do
        [ -n "$name" ] || continue
        if [ "$readings" -eq 0 ] && [ "$unreadable" -eq 0 ]; then
            it_skip_leg "$name hugetlb pages (#2685)" "$name was never running while the sampler read the box" by-design
            continue
        fi
        if [ "$readings" -eq 0 ]; then
            it_fail "$name's smaps_rollup is readable" "$unreadable readings found $name running and could not read it (needs root or sudo -n)"
            continue
        fi
        it_step "$name: peak $peak kB hugetlb over $readings readings ($unreadable unreadable), up to $threads threads"
        assert_num_gt "$name holds hugetlb pages (peak kB over the run)" "$peak" 0
        assert_eq "$name: no instance ran ${HUGEPAGE_SETTLE_S}s without hugetlb pages" "$settled" 0
        if [ "$zeros" -lt "$HUGEPAGE_ZERO_LOOP" ]; then
            it_pass "$name: no restart loop without hugetlb pages"
        else
            it_fail "$name: no restart loop without hugetlb pages" "$zeros instances never held a hugetlb page"
        fi
    done <<<"$1"
}

# Pure: REDUCED_PAGES as the checked-out branch's own overlay file declares it, or empty when the
# file is missing or the assignment is not there to find.
hugepage_reduced_pages() {
    awk -F= '/^REDUCED_PAGES=[0-9]+$/ {print $2; exit}' "$HUGEPAGE_REDUCED_TIER_FILE" 2>/dev/null
}

# The bound the resize itself is proved by (#2685): this run's combined peak (every daemon that
# had at least one reading, rounded to pages the same way the artifact is), plus one second-seed
# cache per process, must fit inside REDUCED_PAGES. Failing this on a run that never exercised a
# seed switch means the pinned value has no room left for the two caches it was sized to include.
hugepage_assert_reduced_tier_bound() { # <tally>
    local name readings unreadable peak_kb rest combined_kb=0 reduced bound_pages combined_pages
    while IFS=$'\t' read -r name readings unreadable peak_kb rest; do
        [ -n "$name" ] || continue
        [ "$readings" -gt 0 ] && combined_kb=$((combined_kb + peak_kb))
    done <<<"$1"
    combined_pages=$(((combined_kb + 2047) / 2048))
    reduced="$(hugepage_reduced_pages)"
    if ! [[ "$reduced" =~ ^[0-9]+$ ]]; then
        it_fail "the appliance's REDUCED_PAGES pin is readable" "got [$reduced] from $HUGEPAGE_REDUCED_TIER_FILE"
        return
    fi
    bound_pages=$((combined_pages + HUGEPAGE_SECOND_SEED_PAGES))
    it_step "combined peak $combined_pages pages + $HUGEPAGE_SECOND_SEED_PAGES second-seed pages = $bound_pages, against REDUCED_PAGES=$reduced"
    assert_num_ge "REDUCED_PAGES covers this run's combined peak plus the second-seed caches" "$reduced" "$bound_pages"
}

# Start after the safety backup. A box with no pool reserved cannot be judged: the daemons fall
# back by design there, so the phase records the absence instead of failing it.
hugepages_begin() {
    local total
    total="$(rx "awk '/^HugePages_Total:/ {print \$2}' /proc/meminfo" 2>/dev/null)"
    if ! [[ "$total" =~ ^[0-9]+$ ]]; then
        # shellcheck disable=SC2034  # shared through the assembled runner scope
        IT_CURRENT_SCENARIO="hugepages"
        it_fail "hugepages: HugePages_Total is readable" "got [$total] from /proc/meminfo"
        return 0
    fi
    if [ "$total" -eq 0 ]; then
        it_skip_phase "hugepages (#2685)" "the box reserves no HugePages (HugePages_Total is 0); reserve the pool to measure it"
        return 0
    fi
    HUGEPAGE_HOST_THREADS="$(rx nproc 2>/dev/null)"
    hugepages_sampler_start "$OUT_DIR/hugepages-samples.tsv" ||
        it_fail "hugepages: sampler started" "could not create $OUT_DIR/hugepages-samples.tsv"
}

# Stop, gate, and write hugepages-peak.json beside the samples. Safe to call when begin did not
# start a sampler.
hugepages_finish() {
    [ -n "$HUGEPAGE_SAMPLER_PID" ] || return 0
    hugepages_sampler_stop
    local tally rounds
    tally="$(hugepage_tally "$HUGEPAGE_SAMPLES" "$HUGEPAGE_SETTLE_S")"
    rounds="$(awk -F'\t' '$2 == "p2pool"' "$HUGEPAGE_SAMPLES" | wc -l | tr -d ' ')"
    # shellcheck disable=SC2034  # shared through the assembled runner scope
    IT_CURRENT_SCENARIO="hugepages"
    if hugepage_report_json "$tally" "$HUGEPAGE_INTERVAL_S" "$HUGEPAGE_SETTLE_S" "$rounds" "${HUGEPAGE_HOST_THREADS:-}" \
        >"$OUT_DIR/hugepages-peak.json"; then
        it_log "hugepages: per-process hugetlb peaks (#2685) -> $OUT_DIR/hugepages-peak.json"
    else
        it_fail "hugepages: hugepages-peak.json written" "jq could not render the tally"
    fi
    hugepage_assert "$tally"
    hugepage_assert_reduced_tier_bound "$tally"
}
