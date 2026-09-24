# shellcheck shell=bash
#
# HugePages held by monerod and p2pool across a live run (#2685).
#
# The appliance's reduced tier reserves a fixed pool (os/overlay/pithead-hugepages), sized from
# the pinned sources rather than from a measurement. This samples what each process actually
# holds, so the value can be set from a peak instead of a derivation, and so a daemon that fell
# back to ordinary memory (the #78 crash loop: p2pool's dataset outside the pool, killed at its
# mem_limit) turns the run red instead of passing unnoticed.
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
# A daemon allocates its RandomX memory at start (p2pool's dataset, monerod's main-seed cache),
# so an instance still at zero after this long has fallen back rather than not got there yet.
# Shorter-lived instances (a restart mid-phase) are judged only by the run's peak.
HUGEPAGE_SETTLE_S=300
HUGEPAGE_SAMPLES=""
HUGEPAGE_SAMPLER_PID=""
HUGEPAGE_HOST_THREADS=""

# One reading per daemon, one TSV line each: epoch, name, pid, starttime, hugetlb kB, threads.
# A daemon not running (or its entrypoint not yet exec'd into it) reads as "-" in every field
# after the name. The pid is the container's init, which both entrypoints exec into; comm
# confirms it before the rollup is read. Another user's rollup needs root, hence sudo -n.
read -r -d '' HUGEPAGE_SAMPLE_SNIPPET <<'SNIPPET'
now=$(date +%s)
for c in monerod p2pool; do
    pid=$(docker inspect -f '{{.State.Pid}}' "$c" 2>/dev/null) || pid=0
    if [ "${pid:-0}" -gt 0 ] 2>/dev/null && [ "$(cat "/proc/$pid/comm" 2>/dev/null)" = "$c" ] &&
        body=$(cat "/proc/$pid/smaps_rollup" 2>/dev/null || sudo -n cat "/proc/$pid/smaps_rollup" 2>/dev/null) &&
        [ -n "$body" ]; then
        start=$(awk '{print $22}' "/proc/$pid/stat" 2>/dev/null)
        threads=$(awk '/^Threads:/ {print $2}' "/proc/$pid/status" 2>/dev/null)
        kb=$(printf '%s\n' "$body" | awk '/^(Private|Shared)_Hugetlb:/ {kb += $2} END {print kb + 0}')
        printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$now" "$c" "$pid" "${start:--}" "$kb" "${threads:--}"
    else
        printf '%s\t%s\t-\t-\t-\t-\n' "$now" "$c"
    fi
done
SNIPPET

hugepage_sample() { rx "$HUGEPAGE_SAMPLE_SNIPPET" 2>/dev/null; }

# Background loop for the life of the run. It polls its parent each second so a harness killed
# mid-run (a cancelled job, a drain) never leaves it behind, and closes the rig-lock descriptors
# it inherited so it can never extend the lock past the harness.
hugepages_sampler_start() { # <samples-file>
    HUGEPAGE_SAMPLES="$1"
    : >"$HUGEPAGE_SAMPLES" || return 1
    local parent=$$
    (
        exec 8>&- 9<&-
        while kill -0 "$parent" 2>/dev/null; do
            hugepage_sample >>"$HUGEPAGE_SAMPLES" </dev/null
            for _ in $(seq "$HUGEPAGE_INTERVAL_S"); do
                kill -0 "$parent" 2>/dev/null || exit 0
                sleep 1
            done
        done
    ) &
    HUGEPAGE_SAMPLER_PID=$!
}

hugepages_sampler_stop() {
    [ -n "$HUGEPAGE_SAMPLER_PID" ] || return 0
    kill "$HUGEPAGE_SAMPLER_PID" 2>/dev/null
    wait "$HUGEPAGE_SAMPLER_PID" 2>/dev/null
    HUGEPAGE_SAMPLER_PID=""
    hugepage_sample >>"$HUGEPAGE_SAMPLES" </dev/null
}

# Pure: per daemon over the sample file, one TSV line each:
#   name  readings  peak_kb  peak_threads  settled_zero_instances
# readings counts samples that found the daemon running. An instance (pid + starttime, so a
# reused pid is a new instance) is settled-zero when it was seen for at least <settle_s> and
# never held a hugetlb page.
hugepage_tally() { # <samples-file> <settle_s>
    awk -F'\t' -v settle="$2" -v procs="$HUGEPAGE_PROCS" '
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
                split(k, p, SUBSEP)
                if (last[k] - first[k] >= settle && imax[k] + 0 == 0) zero[p[1]]++
            }
            split(procs, names, " ")
            for (i = 1; names[i] != ""; i++) {
                c = names[i]
                printf "%s\t%d\t%d\t%d\t%d\n", c, n[c], peak[c], thr[c], zero[c]
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
         processes: (split("\n") | map(select(length > 0) | split("\t")) | map({key: .[0], value: {
             readings: (.[1] | tonumber), peak_kb: (.[2] | tonumber),
             peak_pages: (((.[2] | tonumber) + 2047) / 2048 | floor),
             peak_threads: (.[3] | tonumber), settled_zero_instances: (.[4] | tonumber)}}) | from_entries)}'
}

# The gate. Red when a daemon held no hugetlb page at any reading, or when any instance of it
# ran past the settle window without one. A daemon this run never saw is a skipped leg, not a
# pass: the other phases own "it is running", and this row cannot say anything about it.
hugepage_assert() { # <tally>
    local name readings peak threads zeros
    while IFS=$'\t' read -r name readings peak threads zeros; do
        [ -n "$name" ] || continue
        if [ "$readings" -eq 0 ]; then
            it_skip_leg "$name hugetlb pages (#2685)" "$name was never running while the sampler read the box" by-design
            continue
        fi
        it_step "$name: peak $peak kB hugetlb over $readings readings, up to $threads threads"
        assert_num_gt "$name holds hugetlb pages (peak kB over the run)" "$peak" 0
        assert_eq "$name: no instance ran ${HUGEPAGE_SETTLE_S}s without hugetlb pages" "$zeros" 0
    done <<<"$1"
}

# Start at the head of the destructive run. A box with no pool reserved cannot be judged: the
# daemons fall back by design there, so the row records the absence instead of failing it.
hugepages_begin() {
    local total
    total="$(rx "awk '/^HugePages_Total:/ {print \$2}' /proc/meminfo" 2>/dev/null)"
    if ! [ "${total:-0}" -gt 0 ] 2>/dev/null; then
        it_skip_phase "hugepages (#2685)" "the box reserves no HugePages (HugePages_Total is 0); reserve the pool to measure it"
        return 0
    fi
    HUGEPAGE_HOST_THREADS="$(rx nproc 2>/dev/null)"
    hugepages_sampler_start "$OUT_DIR/hugepages-samples.tsv"
}

# Stop, gate, and write hugepages-peak.json beside the samples. Safe to call when begin skipped.
hugepages_finish() {
    [ -n "$HUGEPAGE_SAMPLER_PID" ] || return 0
    hugepages_sampler_stop
    local tally rounds
    tally="$(hugepage_tally "$HUGEPAGE_SAMPLES" "$HUGEPAGE_SETTLE_S")"
    rounds="$(awk -F'\t' '$2 == "p2pool"' "$HUGEPAGE_SAMPLES" | wc -l | tr -d ' ')"
    hugepage_report_json "$tally" "$HUGEPAGE_INTERVAL_S" "$HUGEPAGE_SETTLE_S" "$rounds" "${HUGEPAGE_HOST_THREADS:-}" \
        >"$OUT_DIR/hugepages-peak.json"
    # shellcheck disable=SC2034  # shared through the assembled runner scope
    IT_CURRENT_SCENARIO="hugepages"
    it_log "hugepages: per-process hugetlb peaks (#2685) -> $OUT_DIR/hugepages-peak.json"
    hugepage_assert "$tally"
}
