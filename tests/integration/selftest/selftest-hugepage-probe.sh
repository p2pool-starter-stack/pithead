#!/usr/bin/env bash
#
# Self-test for the per-process HugePages row (#2685): the tally, the gate and the artifact from
# fixture sample files, the row's wiring in run.sh, the sampler's lifecycle, and the sample
# snippet itself read against a stand-in process on this host, so a change to the /proc parsing
# fails here rather than on the bench.
#
# Run: tests/integration/selftest/selftest-hugepage-probe.sh
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=tests/integration/lib.sh
source "$HERE/../lib.sh"
# shellcheck source=tests/integration/lib/hugepage-probe.sh
source "$HERE/../lib/hugepage-probe.sh"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
T=$'\t'

# Counters around one gate call: how many passes, fails and skips it added.
gate() { # <tally> -> "pass fail skip"
    local p=$IT_PASS f=$IT_FAIL s=$IT_SKIPPED_LEGS
    hugepage_assert "$1" >/dev/null 2>&1
    printf '%s %s %s' $((IT_PASS - p)) $((IT_FAIL - f)) $((IT_SKIPPED_LEGS - s))
    IT_PASS=$p IT_FAIL=$f IT_SKIPPED_LEGS=$s
}
row() { grep "^$1${T}" <<<"$2"; }

echo "== tally: readings, peak, threads and instances per daemon =="
cat >"$TMP/steady.tsv" <<EOF
1000${T}monerod${T}11${T}500${T}0${T}8
1000${T}p2pool${T}22${T}600${T}2179072${T}12
1010${T}monerod${T}11${T}500${T}524288${T}8
1010${T}p2pool${T}22${T}600${T}2703360${T}14
1400${T}monerod${T}11${T}500${T}557056${T}9
1400${T}p2pool${T}22${T}600${T}2703360${T}14
EOF
tally="$(hugepage_tally "$TMP/steady.tsv" 300)"
assert_eq "monerod: 3 readings, none unreadable, peak 557056 kB, 9 threads, no zero instance" \
    "$(row monerod "$tally")" "monerod${T}3${T}0${T}557056${T}9${T}0${T}0"
assert_eq "p2pool: 3 readings, none unreadable, peak 2703360 kB, 14 threads, no zero instance" \
    "$(row p2pool "$tally")" "p2pool${T}3${T}0${T}2703360${T}14${T}0${T}0"
assert_eq "a zero first reading (cache still allocating) is not a fallback" "$(gate "$tally")" "6 0 0"

echo "== gate: a daemon that never held a page is red =="
sed "s/${T}2[0-9]*${T}1[24]\$/${T}0${T}12/" "$TMP/steady.tsv" >"$TMP/p2pool-zero.tsv"
tally="$(hugepage_tally "$TMP/p2pool-zero.tsv" 300)"
assert_eq "p2pool at zero throughout: peak 0, one settled and zero-only instance" \
    "$(row p2pool "$tally")" "p2pool${T}3${T}0${T}0${T}12${T}1${T}1"
assert_eq "p2pool's peak and settle rows go red, monerod's stay green" "$(gate "$tally")" "4 2 0"

echo "== gate: a restarted instance that settles without pages is red under a good peak =="
cat >"$TMP/restart.tsv" <<EOF
$(cat "$TMP/steady.tsv")
1410${T}p2pool${T}33${T}900${T}0${T}12
1600${T}p2pool${T}33${T}900${T}0${T}12
1720${T}p2pool${T}33${T}900${T}0${T}12
EOF
tally="$(hugepage_tally "$TMP/restart.tsv" 300)"
assert_eq "the second p2pool instance (310 s at zero) is settled zero" "$(row p2pool "$tally" | cut -f4,6,7)" "2703360${T}1${T}1"
assert_eq "peak passes, the settle row fails" "$(gate "$tally")" "5 1 0"
tally="$(hugepage_tally "$TMP/restart.tsv" 400)"
assert_eq "a shorter-lived zero instance is not settled" "$(row p2pool "$tally" | cut -f6)" "0"

echo "== gate: a crash loop after one healthy instance is red (#78) =="
{
    cat "$TMP/steady.tsv"
    for i in 1 2 3; do
        printf '%s\tp2pool\t%s\t%s\t0\t12\n' $((1400 + i * 20)) $((40 + i)) $((1000 + i))
        printf '%s\tp2pool\t%s\t%s\t0\t12\n' $((1410 + i * 20)) $((40 + i)) $((1000 + i))
    done
} >"$TMP/loop.tsv"
tally="$(hugepage_tally "$TMP/loop.tsv" 300)"
assert_eq "three short instances at zero: none settled, three zero-only" "$(row p2pool "$tally" | cut -f6,7)" "0${T}3"
assert_eq "the loop row fails under a good peak" "$(gate "$tally")" "5 1 0"
head -n -2 "$TMP/loop.tsv" >"$TMP/two-restarts.tsv"
assert_eq "two restarts read before their allocation are not a loop" \
    "$(gate "$(hugepage_tally "$TMP/two-restarts.tsv" 300)")" "6 0 0"

echo "== gate: a reused pid with a new starttime is a new instance =="
cat >"$TMP/reuse.tsv" <<EOF
1000${T}p2pool${T}22${T}600${T}2703360${T}14
1400${T}p2pool${T}22${T}999${T}0${T}12
1800${T}p2pool${T}22${T}999${T}0${T}12
EOF
assert_eq "pid 22 restarted at zero is judged apart from its first life" \
    "$(row p2pool "$(hugepage_tally "$TMP/reuse.tsv" 300)" | cut -f6)" "1"

echo "== gate: absent daemons skip, unreadable ones fail =="
cat >"$TMP/absent.tsv" <<EOF
1000${T}monerod${T}-${T}-${T}-${T}-
1000${T}p2pool${T}22${T}600${T}2703360${T}14
1010${T}monerod${T}-${T}-${T}-${T}-
1010${T}p2pool${T}22${T}600${T}garbage${T}14
EOF
tally="$(hugepage_tally "$TMP/absent.tsv" 300)"
assert_eq "monerod never seen: zero readings" "$(row monerod "$tally" | cut -f2,3)" "0${T}0"
assert_eq "the garbage p2pool row is not a reading" "$(row p2pool "$tally" | cut -f2)" "1"
assert_eq "monerod skips one leg, p2pool passes its three" "$(gate "$tally")" "3 0 1"
sed "s/^\(....${T}monerod${T}\)-${T}-${T}-${T}-/\111${T}500${T}?${T}8/" "$TMP/absent.tsv" >"$TMP/unreadable.tsv"
tally="$(hugepage_tally "$TMP/unreadable.tsv" 300)"
assert_eq "a running monerod whose rollup cannot be read counts as unreadable" "$(row monerod "$tally" | cut -f2,3)" "0${T}2"
assert_eq "an unreadable daemon fails instead of skipping" "$(gate "$tally")" "3 1 0"

echo "== artifact: peaks in kB and 2 MiB pages =="
json="$(hugepage_report_json "$(hugepage_tally "$TMP/steady.tsv" 300)" 10 300 3 16)"
assert_eq "p2pool peak pages (2703360 kB / 2048)" "$(jq -r '.processes.p2pool.peak_pages' <<<"$json")" "1320"
assert_eq "monerod peak_kb and peak_threads carried" "$(jq -c '.processes.monerod | [.peak_kb, .peak_threads]' <<<"$json")" "[557056,9]"
assert_eq "instance counts carried" "$(jq -c '.processes.p2pool | [.readings, .unreadable, .settled_zero_instances, .zero_only_instances]' <<<"$json")" "[3,0,0,0]"
assert_eq "run metadata carried" "$(jq -c '[.interval_s, .settle_s, .sample_rounds, .host_threads]' <<<"$json")" "[10,300,3,16]"
json="$(hugepage_report_json "p2pool${T}1${T}0${T}2049${T}1${T}0${T}0" 10 300 1 "")"
assert_eq "a partial page rounds up (2049 kB -> 2 pages)" "$(jq -r '.processes.p2pool.peak_pages' <<<"$json")" "2"
assert_eq "an unread host thread count is null, not 0" "$(jq -r '.host_threads' <<<"$json")" "null"

echo "== run.sh: sampled across the destructive run, gated before each summary after it =="
body="$(sed -n '/^main() {/,/^}/p' "$HERE/../run.sh")"
assert_eq "begin sits right after the safety backup's abort-restore is armed" \
    "$(grep -A2 'arm_safety_abort_restore$' <<<"$body" | grep -c '^    hugepages_begin$')" "1"
assert_eq "every summary after begin is preceded by finish" \
    "$(sed -n '/hugepages_begin/,$p' <<<"$body" | grep -B1 -E '^ +summary$' | grep -cE '^ +hugepages_finish$')" \
    "$(sed -n '/hugepages_begin/,$p' <<<"$body" | grep -cE '^ +summary$')"

echo "== begin/finish: skip, fail and measure =="
OUT_DIR="$TMP/out"
mkdir -p "$OUT_DIR"
HUGEPAGE_INTERVAL_S=1
real_rx="$(declare -f rx)"
rx() { # the box: meminfo, nproc, and one fixture round per sample
    case "$1" in
    *HugePages_Total*) printf '%s' "${FAKE_TOTAL-}" ;;
    nproc) echo 16 ;;
    *) printf '%s\tmonerod\t11\t500\t524288\t8\n%s\tp2pool\t22\t600\t2703360\t14\n' "$(date +%s)" "$(date +%s)" ;;
    esac
}
skipped=$IT_SKIPPED_PHASES
FAKE_TOTAL=0 hugepages_begin >/dev/null 2>&1
assert_eq "a box with no pool skips the phase" "$((IT_SKIPPED_PHASES - skipped))" "1"
assert_eq "and starts no sampler" "$HUGEPAGE_SAMPLER_PID" ""
failed=$IT_FAIL
FAKE_TOTAL="" hugepages_begin >/dev/null 2>&1
assert_eq "an unreadable HugePages_Total fails rather than skipping" "$((IT_FAIL - failed))" "1"
IT_FAIL=$failed
passed=$IT_PASS failed=$IT_FAIL
hugepages_finish >/dev/null 2>&1
assert_eq "finish without a sampler gates nothing" "$((IT_PASS - passed)) $((IT_FAIL - failed))" "0 0"
exec 9<"$TMP/steady.tsv"
FAKE_TOTAL=3072 hugepages_begin >/dev/null 2>&1
exec 9<&-
sampler=$HUGEPAGE_SAMPLER_PID
assert_ne "a reserved pool starts the sampler" "$sampler" ""
sleep 2
if [ -e "/proc/$sampler/fd/9" ]; then
    it_fail "the sampler does not hold the rig-lock descriptor" "fd 9 open in pid $sampler"
else
    it_pass "the sampler does not hold the rig-lock descriptor"
fi
passed=$IT_PASS failed=$IT_FAIL
hugepages_finish >/dev/null 2>&1
gated="$((IT_PASS - passed)) $((IT_FAIL - failed))"
if kill -0 "$sampler" 2>/dev/null; then it_fail "finish stops the sampler" "pid $sampler still running"; else it_pass "finish stops the sampler"; fi
assert_num_ge "the sampler read at least twice plus the final round" "$(grep -c "${T}p2pool${T}" "$OUT_DIR/hugepages-samples.tsv")" 3
assert_eq "hugepages-peak.json carries both peaks" \
    "$(jq -c '[.processes.monerod.peak_pages, .processes.p2pool.peak_pages, .host_threads]' "$OUT_DIR/hugepages-peak.json")" "[256,1320,16]"
assert_eq "the gate ran six green rows" "$gated" "6 0"
IT_PASS=$((IT_PASS - 6))
eval "$real_rx"

echo "== sampler: exits with its parent =="
bash -c 'source "$1/../lib.sh"; source "$1/../lib/hugepage-probe.sh"; HUGEPAGE_INTERVAL_S=30; hugepage_sample() { :; }; hugepages_sampler_start "$2/orphan.tsv"; echo "$HUGEPAGE_SAMPLER_PID"' _ "$HERE" "$TMP" >"$TMP/orphan.pid"
sleep 2
if kill -0 "$(cat "$TMP/orphan.pid")" 2>/dev/null; then
    it_fail "a sampler whose harness died stops within its poll" "pid $(cat "$TMP/orphan.pid") outlived its parent"
else
    it_pass "a sampler whose harness died stops within its poll"
fi

echo "== sample snippet: reads a live process through a stand-in docker =="
if [ -r /proc/self/smaps_rollup ]; then
    mkdir -p "$TMP/bin"
    cp "$(command -v sleep)" "$TMP/bin/p2pool"
    "$TMP/bin/p2pool" 60 &
    stand_in=$!
    cat >"$TMP/bin/docker" <<EOF
#!/usr/bin/env bash
[ "\${4:-}" = p2pool ] && echo $stand_in && exit 0
echo 0
EOF
    chmod +x "$TMP/bin/docker"
    sample="$(IT_MODE=local IT_REMOTE_DIR="$TMP" PATH="$TMP/bin:$PATH" hugepage_sample)"
    start="$(awk '{print $22}' "/proc/$stand_in/stat")"
    kill "$stand_in" 2>/dev/null
    wait "$stand_in" 2>/dev/null
    stand_row="$(row "[0-9]*${T}p2pool" "$sample")"
    assert_eq "the running daemon reads its pid" "$(cut -f3 <<<"$stand_row")" "$stand_in"
    assert_eq "its starttime from /proc/<pid>/stat" "$(cut -f4 <<<"$stand_row")" "$start"
    assert_eq "an ordinary process holds 0 kB hugetlb" "$(cut -f5 <<<"$stand_row")" "0"
    assert_eq "its thread count" "$(cut -f6 <<<"$stand_row")" "1"
    assert_eq "a daemon docker has no pid for reads as absent" \
        "$(row "[0-9]*${T}monerod" "$sample" | cut -f3-)" "-${T}-${T}-${T}-"
    cat >"$TMP/bin/docker" <<EOF
#!/usr/bin/env bash
echo $$
EOF
    assert_eq "a pid whose comm is not the daemon (entrypoint not yet exec'd) reads as absent" \
        "$(IT_MODE=local IT_REMOTE_DIR="$TMP" PATH="$TMP/bin:$PATH" hugepage_sample | grep -c "${T}-${T}-${T}-${T}-\$")" "2"
else
    it_fail "sample snippet" "this host has no /proc/self/smaps_rollup; run the selftest on Linux"
fi

echo ""
echo "selftest-hugepage-probe: $IT_PASS passed, $IT_FAIL failed"
[ "$IT_FAIL" -eq 0 ] || exit 1
