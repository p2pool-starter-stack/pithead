# shellcheck shell=bash
: "${STACK_SUITE:?is unset: this file is a tests/stack/run.sh fragment, not a script — run tests/stack/run.sh}"
# Control-channel results/ retention domain (#1990): control_prune_results in
# lib/pithead/49-control-request-loop.sh keeps the host-written results spool within its count, age
# and byte caps without deleting the appliance's update ledger, the in-flight request's result, a
# backup still inside its download window, or half of a backup result/archive pair. Sourced by
# tests/stack/run.sh. Standalone-sourceable once tests/stack/lib.sh has been sourced: $SANDBOX is
# the only name it reads without assigning, it builds its own control directories under $SANDBOX,
# and it unsets what it exports before it ends.

: "${SANDBOX:?}"

echo "== control channel: results/ pruning (#1990) =="
PRC="$SANDBOX/ctrl1990"
mkdir -p "$PRC/results"

backdate() { # <file> <minutes-ago>
    touch -t "$(date -d "$2 minutes ago" +%Y%m%d%H%M 2>/dev/null || date -v-"$2"M +%Y%m%d%H%M)" "$1"
}

# Protected files: the appliance's update ledger, and the in-flight request's own result. Nothing
# on this drain's own request queue exists at prune time (it runs BEFORE the queue is read) — the
# routine's real guarantee is that the single newest result in results/ is never a candidate, which
# is what makes it safe for a verb like os-download that keeps rewriting its own result as the
# newest file for as long as it runs. This fixture stands the in-flight result up as that newest
# file — created last, strictly after everything else below — to prove that guarantee directly.
echo '{"step":"idle"}' >"$PRC/results/os-update-state.json"
backdate "$PRC/results/os-update-state.json" 100000 # ancient — must survive on name alone

# Excess old plain results: 5 aged past CONTROL_RESULT_MAX_AGE_S, 3 fresh (but still older than
# the in-flight result created below).
i=1
while [ "$i" -le 5 ]; do
    f="$PRC/results/a0a0a0a0-0000-4000-8000-00000000010$i.json"
    echo '{"status":"applied","ts":0}' >"$f"
    backdate "$f" 2000 # older than the 1-day default (1440 min)
    i=$((i + 1))
done
i=1
while [ "$i" -le 3 ]; do
    f="$PRC/results/a0a0a0a0-0000-4000-8000-00000000020$i.json"
    echo '{"status":"applied","ts":0}' >"$f"
    backdate "$f" 1
    i=$((i + 1))
done

# Excess backup archives: 2 past their download window (paired with a result JSON each), 1 fresh
# inside the window — untouchable regardless of count.
i=1
while [ "$i" -le 2 ]; do
    id="a0a0a0a0-0000-4000-8000-00000000030$i"
    printf 'FAKE-ENCRYPTED-BYTES' >"$PRC/results/$id.tar.gz.enc"
    echo '{"status":"applied","archive":"a.enc","ts":0}' >"$PRC/results/$id.json"
    backdate "$PRC/results/$id.tar.gz.enc" 120 # past the 1-hour default window
    backdate "$PRC/results/$id.json" 120
    i=$((i + 1))
done
fresh_id="a0a0a0a0-0000-4000-8000-000000000399"
printf 'FRESH-ENCRYPTED-BYTES' >"$PRC/results/$fresh_id.tar.gz.enc"
echo '{"status":"applied","archive":"b.enc","ts":0}' >"$PRC/results/$fresh_id.json"

# An old result stays protected only while its request claim is live.
inflight="a0a0a0a0-0000-4000-8000-0000000000ff"
echo '{"status":"running","ts":0}' >"$PRC/results/$inflight.json"
backdate "$PRC/results/$inflight.json" 2000
printf '{"id":"%s"}\n' "$inflight" >"$PRC/.claim.1990"

before_count=$(find "$PRC/results" -maxdepth 1 -type f | wc -l | tr -d ' ')
[ "$before_count" -ge 12 ] &&
    ok "excess results and archives are on disk before pruning (red without the fix)" ||
    bad "excess results and archives are on disk before pruning" "got: $before_count files"

export CONTROL_RESULT_MAX_COUNT=2 CONTROL_BACKUP_MAX_COUNT=1
run_sourced "$SANDBOX" control_prune_results "$PRC" >/dev/null 2>&1

[ -f "$PRC/results/os-update-state.json" ] &&
    ok "os-update-state.json survives pruning however old it is" ||
    bad "os-update-state.json survives pruning however old it is" "missing"
[ -f "$PRC/results/$inflight.json" ] &&
    ok "the in-flight request's result survives pruning" ||
    bad "the in-flight request's result survives pruning" "missing"

remaining_plain=$(find "$PRC/results" -maxdepth 1 -type f -name '*.json' \
    ! -name 'os-update-state.json' ! -name "$inflight.json" \
    ! -name "a0a0a0a0-0000-4000-8000-000000000301.json" \
    ! -name "a0a0a0a0-0000-4000-8000-000000000302.json" \
    ! -name "$fresh_id.json" | wc -l | tr -d ' ')
[ "$remaining_plain" -eq 1 ] &&
    ok "plain results are capped at CONTROL_RESULT_MAX_COUNT (2, minus the active claim)" ||
    bad "plain results are capped at CONTROL_RESULT_MAX_COUNT (2, minus the active claim)" "got: $remaining_plain"
i=1
while [ "$i" -le 5 ]; do
    [ -f "$PRC/results/a0a0a0a0-0000-4000-8000-00000000010$i.json" ] &&
        bad "aged-out result is pruned" "result $i still present" ||
        ok "aged-out result is pruned"
    i=$((i + 1))
done

[ -f "$PRC/results/$fresh_id.tar.gz.enc" ] && [ -f "$PRC/results/$fresh_id.json" ] &&
    ok "a backup archive inside its download window survives, regardless of count" ||
    bad "a backup archive inside its download window survives, regardless of count" "missing"
backdate "$PRC/results/$fresh_id.tar.gz.enc" 120
backdate "$PRC/results/$fresh_id.json" 120
export CONTROL_BACKUP_MAX_COUNT=0
run_sourced "$SANDBOX" control_prune_results "$PRC" >/dev/null 2>&1
[ ! -f "$PRC/results/$fresh_id.tar.gz.enc" ] && [ ! -f "$PRC/results/$fresh_id.json" ] &&
    ok "a backup pair becomes eligible after its download window" ||
    bad "a backup pair becomes eligible after its download window" "archive: $([ -f "$PRC/results/$fresh_id.tar.gz.enc" ] && echo present || echo missing), json: $([ -f "$PRC/results/$fresh_id.json" ] && echo present || echo missing)"
unset CONTROL_BACKUP_MAX_COUNT
remaining_archives=$(find "$PRC/results" -maxdepth 1 -type f -name '*.tar.gz.enc' \
    ! -name "$fresh_id.tar.gz.enc" | wc -l | tr -d ' ')
[ "$remaining_archives" -le 1 ] &&
    ok "archives past their window are capped at CONTROL_BACKUP_MAX_COUNT (1)" ||
    bad "archives past their window are capped at CONTROL_BACKUP_MAX_COUNT (1)" "got: $remaining_archives"
[ -f "$PRC/results/a0a0a0a0-0000-4000-8000-000000000301.json" ] &&
    [ ! -f "$PRC/results/a0a0a0a0-0000-4000-8000-000000000301.tar.gz.enc" ] &&
    bad "a pruned archive's own result JSON is pruned with it" "json survived alone" ||
    ok "a pruned archive's own result JSON is pruned with it"
unset CONTROL_RESULT_MAX_COUNT CONTROL_BACKUP_MAX_COUNT

echo "== control channel: results/ pruning — total-bytes backstop (#1990) =="
PRB="$SANDBOX/ctrl1990bytes"
mkdir -p "$PRB/results"
echo '{"step":"idle"}' >"$PRB/results/os-update-state.json"
backdate "$PRB/results/os-update-state.json" 100000
i=1
while [ "$i" -le 4 ]; do
    f="$PRB/results/a0a0a0a0-0000-4000-8000-00000000040$i.json"
    head -c 2000 </dev/zero | tr '\0' 'x' >"$f"
    backdate "$f" $((i * 10)) # oldest first as i grows
    i=$((i + 1))
done
# A backup pair whose RESULT JSON is the oldest file in the directory (so it is the byte cap's
# first eviction candidate by mtime) but whose ARCHIVE is fresh, inside its download window — the
# pairing the count/age pass protects explicitly. Proves the byte cap does not orphan it by
# deleting the json out from under a still-downloadable archive.
protected_id="a0a0a0a0-0000-4000-8000-000000000501"
printf 'IN-WINDOW-ARCHIVE-BYTES' >"$PRB/results/$protected_id.tar.gz.enc"
echo '{"status":"applied","archive":"c.enc","ts":0}' >"$PRB/results/$protected_id.json"
backdate "$PRB/results/$protected_id.json" 500 # oldest of all — first in line for eviction
# The cap is measured from an otherwise-identical directory holding only protected files: `du`
# includes filesystem-specific directory blocks, so a hand-calculated byte margin is not portable.
before_bytes=$(du -sk "$PRB/results" | awk '{print $1 * 1024}')
mkdir -p "$PRB-floor/results"
cp "$PRB/results/os-update-state.json" "$PRB/results/a0a0a0a0-0000-4000-8000-000000000401.json" \
    "$PRB/results/$protected_id.json" "$PRB/results/$protected_id.tar.gz.enc" "$PRB-floor/results/"
floor_bytes=$(du -sk "$PRB-floor/results" | awk '{print $1 * 1024}')
export CONTROL_RESULTS_MAX_BYTES="$floor_bytes" CONTROL_RESULT_MAX_COUNT=100 CONTROL_RESULT_MAX_AGE_S=100000
run_sourced "$SANDBOX" control_prune_results "$PRB" >/dev/null 2>&1
after_bytes=$(du -sk "$PRB/results" | awk '{print $1 * 1024}')
[ "$before_bytes" -gt "$floor_bytes" ] &&
    ok "the sandbox starts over the byte cap (red without the fix)" ||
    bad "the sandbox starts over the byte cap" "got: $before_bytes bytes"
[ "$after_bytes" -lt "$before_bytes" ] &&
    ok "total bytes shrink once they exceed CONTROL_RESULTS_MAX_BYTES" ||
    bad "total bytes shrink once they exceed CONTROL_RESULTS_MAX_BYTES" "got: $after_bytes bytes, was $before_bytes"
[ "$after_bytes" -le "$floor_bytes" ] &&
    ok "total bytes stay within a byte cap that can retain every protected file" ||
    bad "total bytes stay within a byte cap that can retain every protected file" "got: $after_bytes bytes, cap: $floor_bytes"
[ -f "$PRB/results/os-update-state.json" ] &&
    ok "os-update-state.json survives the byte-cap eviction even though it is the oldest file" ||
    bad "os-update-state.json survives the byte-cap eviction even though it is the oldest file" "missing"
[ ! -f "$PRB/results/a0a0a0a0-0000-4000-8000-000000000404.json" ] &&
    ok "the byte-cap eviction removes the oldest results first" ||
    bad "the byte-cap eviction removes the oldest results first" "oldest survived while newer was evicted"
[ -f "$PRB/results/$protected_id.json" ] && [ -f "$PRB/results/$protected_id.tar.gz.enc" ] &&
    ok "the byte cap never orphans an in-window backup by deleting its result JSON alone" ||
    bad "the byte cap never orphans an in-window backup by deleting its result JSON alone" \
        "json: $([ -f "$PRB/results/$protected_id.json" ] && echo present || echo missing), archive: $([ -f "$PRB/results/$protected_id.tar.gz.enc" ] && echo present || echo missing)"

PRT="$SANDBOX/ctrl1990temps"
mkdir -p "$PRT/results"
temp_id="a0a0a0a0-0000-4000-8000-000000000601"
printf '{"passphrase":"STRANDED-SECRET"}' >"$PRT/results/.$temp_id.json.tmp"
backdate "$PRT/results/.$temp_id.json.tmp" 120
printf '{"passphrase":"LIVE-SECRET"}' >"$PRT/results/.fresh.json.tmp"
export CONTROL_BACKUP_DOWNLOAD_WINDOW_S=60
run_sourced "$SANDBOX" control_prune_results "$PRT" >/dev/null 2>&1
[ ! -f "$PRT/results/.$temp_id.json.tmp" ] &&
    ok "a stale atomic result temp is removed after the download window" ||
    bad "a stale atomic result temp is removed after the download window" "still present"
[ -f "$PRT/results/.fresh.json.tmp" ] &&
    ok "a fresh atomic result temp is not interrupted" ||
    bad "a fresh atomic result temp is not interrupted" "missing"

PRP="$SANDBOX/ctrl1990pair"
mkdir -p "$PRP/results"
echo '{"step":"idle"}' >"$PRP/results/os-update-state.json"
pair_id="a0a0a0a0-0000-4000-8000-000000000701"
echo '{"status":"applied","archive":"x.enc"}' >"$PRP/results/$pair_id.json"
head -c 2000 </dev/zero | tr '\0' x >"$PRP/results/$pair_id.tar.gz.enc"
backdate "$PRP/results/$pair_id.json" 240
backdate "$PRP/results/$pair_id.tar.gz.enc" 120
echo '{"status":"running"}' >"$PRP/results/a0a0a0a0-0000-4000-8000-0000000007ff.json"
pair_before=$(du -sk "$PRP/results" | awk '{print $1 * 1024}')
export CONTROL_RESULTS_MAX_BYTES=$((pair_before - 1)) CONTROL_RESULT_MAX_COUNT=100 CONTROL_RESULT_MAX_AGE_S=100000
run_sourced "$SANDBOX" control_prune_results "$PRP" >/dev/null 2>&1
[ ! -f "$PRP/results/$pair_id.json" ] && [ ! -f "$PRP/results/$pair_id.tar.gz.enc" ] &&
    ok "byte eviction removes an expired backup result and archive together" ||
    bad "byte eviction removes an expired backup result and archive together" "json: $([ -f "$PRP/results/$pair_id.json" ] && echo present || echo missing), archive: $([ -f "$PRP/results/$pair_id.tar.gz.enc" ] && echo present || echo missing)"
unset CONTROL_RESULTS_MAX_BYTES CONTROL_RESULT_MAX_COUNT CONTROL_RESULT_MAX_AGE_S
unset CONTROL_BACKUP_DOWNLOAD_WINDOW_S
unset -f backdate
unset PRC PRB PRT PRP before_count remaining_plain remaining_archives fresh_id inflight before_bytes after_bytes floor_bytes protected_id temp_id pair_id pair_before
