# shellcheck shell=bash
: "${STACK_SUITE:?is unset: this file is a tests/stack/run.sh fragment, not a script — run tests/stack/run.sh}"
# Control-channel backup-verb domain (#1105 Phase 1, appliance lane): the backup verb sections
# (#908). control_backup generates its OWN passphrase rather than accepting one from the container
# and runs the real backup as a child "$self backup -y", so stack_backup's own error() exit cannot
# take the drain loop's other pending requests with it; the one-time kit it hands back is visible
# for its TTL and redacted afterwards, including when a runner dies mid-TTL; and the failure and
# throttle paths are covered alongside.
# Sourced by tests/stack/run.sh.
#
# This domain IS standalone-sourceable once tests/stack/lib.sh has been sourced, and it needs
# nothing from any sibling domain file. It is not a consumer of the shared control sandbox: it
# never calls build_control_sandbox(), and it never reads $C, $CTRL_LOG or the request-spool
# globals. It builds its own control directory under $SANDBOX instead. So the add-only-ssrf
# disclosure precedent that governs the pure-consumer control domains does not apply here, and
# neither does the position lock that comes with it: this domain reads no state a sibling leaves
# behind, writes nothing outside its own directory under $SANDBOX, and unsets the environment it
# exports before it ends. Both directions were checked, and both are re-derivable with grep here.
#
# Re-derivations, audited over this WHOLE file, this header included. The audit script is
# lane-local and is NOT in this repo, so nothing below rests on it: each claim is written to be
# re-derived here with git and grep alone, and should be treated as a claim to check.
# - $SANDBOX is the ONLY name this file reads without assigning. It is a lib.sh top-level constant,
#   assigned at column 1 rather than inside a function — the distinction that matters, because a
#   name a provider assigns only inside a function reaches a domain file as an ordering dependency
#   and not as a constant. The guard below states that single requirement explicitly.
# - $BKC is assigned here, in the moved text, not inherited.
# - The lib.sh helpers this domain calls (assert_contains, assert_eq, bad, ok, run_sourced,
#   run_sourced_e) are
#   likewise defined at lib.sh's top level.

: "${SANDBOX:?}"

# ---------------------------------------------------------------------------
echo "== control channel: backup verb (#908) =="
# control_backup generates its OWN passphrase (never accepted from the container), runs the
# real backup as a CHILD "$self backup -y" (stack_backup's own error() exits its process, which
# must not take the drain loop's other pending requests with it), and hands back a one-time kit
# through results/. A stub self reproduces stack_backup's own "Backup written to: <path>" log
# line so this stays a fast, docker-free test of the GLUE — the archive mechanics themselves are
# already covered by the backup/restore round-trip tests above (#140/#374).
BKC="$SANDBOX/ctrl908"
mkdir -p "$BKC/staged" "$BKC/results" "$BKC/audit"
cat >"$BKC/self" <<'EOF'
#!/usr/bin/env bash
echo "$*" >>"${SELF_LOG:-/dev/null}"
printf '%s\n' "${PITHEAD_BACKUP_PASSPHRASE:-<empty>}" >>"${PASS_LOG:-/dev/null}"
if [ "${BACKUP_FAIL:-0}" = "1" ]; then
    echo "boom: disk full" >&2
    exit 1
fi
mkdir -p "$(dirname "$FAKE_ARCHIVE")"
printf 'FAKE-ENCRYPTED-BYTES' >"$FAKE_ARCHIVE"
echo "[pithead] Backup written to: $FAKE_ARCHIVE"
exit 0
EOF
chmod +x "$BKC/self"
export PITHEAD_SELF="$BKC/self"
export SELF_LOG="$BKC/self.log"
export PASS_LOG="$BKC/pass.log"
export CONTROL_BACKUP_KIT_TTL_S=0 # redact immediately — this block only checks the applied shape

bid1="a0a0a0a0-0000-4000-8000-000000000001"
export FAKE_ARCHIVE="$BKC/fake-backups/pithead-backup-20260813-000000.tar.gz.enc"
: >"$SELF_LOG"
: >"$PASS_LOG"
printf '{"id":"%s","action":"backup","actor":"admin"}\n' "$bid1" >"$BKC/req1.json"
run_sourced_e "$SANDBOX" control_process_request "$BKC/req1.json" "$BKC" >/dev/null 2>&1
assert_eq "backup runs the fixed 'backup -y' verb (never --no-encrypt)" "$(cat "$SELF_LOG")" "backup -y"
assert_eq "backup result is applied" "$(jq -r .status "$BKC/results/$bid1.json")" "applied"
pass1="$(cat "$PASS_LOG")"
{ [ -n "$pass1" ] && [ "$pass1" != "<empty>" ]; } &&
    ok "the child gets a non-empty passphrase (via env, never argv)" ||
    bad "the child gets a non-empty passphrase (via env, never argv)" "got: $pass1"
assert_eq "the passphrase never rides argv (the child's own argv log shows only 'backup -y')" \
    "$(cat "$SELF_LOG")" "backup -y"
assert_eq "the kit names the archive by basename" \
    "$(jq -r .archive "$BKC/results/$bid1.json")" "pithead-backup-20260813-000000.tar.gz.enc"
assert_contains "the kit lists what the archive holds" \
    "$(jq -r '.contents | join(",")' "$BKC/results/$bid1.json")" "config.json"
[ -f "$BKC/results/$bid1.tar.gz.enc" ] &&
    ok "the archive lands under results/ (the container's existing ro mount — no new bind mount)" ||
    bad "the archive lands under results/ (the container's existing ro mount — no new bind mount)" "missing"
assert_eq "the archive's content is preserved by the move into results/" \
    "$(cat "$BKC/results/$bid1.tar.gz.enc")" "FAKE-ENCRYPTED-BYTES"
assert_contains "backup is audited applied" \
    "$(cat "$BKC/audit/control.log")" '"action":"backup","status":"applied"'
# TTL=0 above means the redaction ran synchronously before control_process_request returned.
assert_eq "the passphrase is gone once the TTL elapses (redacted in place, whether read or not)" \
    "$(jq -r '.passphrase // "null"' "$BKC/results/$bid1.json")" "null"
assert_contains "the redaction note explains the passphrase is gone" \
    "$(jq -r .note "$BKC/results/$bid1.json")" "no longer available"
assert_eq "the archive name survives the redaction (ciphertext stays downloadable)" \
    "$(jq -r .archive "$BKC/results/$bid1.json")" "pithead-backup-20260813-000000.tar.gz.enc"

echo "== control channel: backup verb — the kit is visible before its TTL, gone after (#908) =="
# A wider TTL, checked mid-flight: the passphrase is readable for a real window (long enough for
# an ordinary dashboard poll), then null either way — "consumed or not, it's gone".
rm -f "$BKC/staged/.backup-stamp" # bid1 above already claimed the 10-minute throttle
bid2="a0a0a0a0-0000-4000-8000-000000000002"
export FAKE_ARCHIVE="$BKC/fake-backups/pithead-backup-20260813-000001.tar.gz.enc"
export CONTROL_BACKUP_KIT_TTL_S=3
: >"$SELF_LOG"
: >"$PASS_LOG"
printf '{"id":"%s","action":"backup","actor":"admin"}\n' "$bid2" >"$BKC/req2.json"
run_sourced_e "$SANDBOX" control_process_request "$BKC/req2.json" "$BKC" >/dev/null 2>&1 &
bg_pid=$!
# The mid-flight read races the background write, so it waits on the condition rather than on a
# fixed budget; why a tick budget is wrong is #1495's lesson and lives on wait_while_alive itself.
# What is specific to this row: when the old `sleep 0.5` lost, jq read a result file that was not
# there yet and the row redded with `got: null`, the exact text a real TTL defect prints. The
# writer cannot exit before it redacts (lib/pithead/45-control-backup.sh), so it outlives the
# window by construction and a give-up means it published nothing at all.
bkc_kit_published() { # #1495: see wait_while_alive in lib.sh
    mid_pass="$(jq -r '.passphrase // "null"' "$BKC/results/$bid2.json" 2>/dev/null)"
    [ -n "$mid_pass" ] && [ "$mid_pass" != "null" ]
}
wait_while_alive "$bg_pid" bkc_kit_published &&
    ok "the passphrase IS present while inside the TTL window" ||
    bad "the passphrase IS present while inside the TTL window" \
        "got: ${mid_pass:-none} — the writer exited without publishing one: a broken write, not a slow box"
assert_eq "the kit's passphrase is exactly what the child received (same secret both ends)" \
    "$mid_pass" "$(cat "$PASS_LOG")"
wait "$bg_pid"
assert_eq "the passphrase is null once the TTL elapses" \
    "$(jq -r '.passphrase // "null"' "$BKC/results/$bid2.json" 2>/dev/null)" "null"
[ -f "$BKC/results/$bid2.tar.gz.enc" ] &&
    ok "the archive file itself is untouched by the redaction" ||
    bad "the archive file itself is untouched by the redaction" "missing"
unset bg_pid mid_pass
unset -f bkc_kit_published

echo "== control channel: backup verb — failure and throttle (#908) =="
rm -f "$BKC/staged/.backup-stamp" # bid2 above already claimed the 10-minute throttle
bid3="a0a0a0a0-0000-4000-8000-000000000003"
export CONTROL_BACKUP_KIT_TTL_S=0
export BACKUP_FAIL=1
: >"$SELF_LOG"
printf '{"id":"%s","action":"backup","actor":"admin"}\n' "$bid3" >"$BKC/req3.json"
run_sourced_e "$SANDBOX" control_process_request "$BKC/req3.json" "$BKC" >/dev/null 2>&1
assert_eq "a failed child backup is reported failed, not applied" \
    "$(jq -r .status "$BKC/results/$bid3.json")" "failed"
assert_contains "the failure carries the child's own error tail" \
    "$(jq -r .log "$BKC/results/$bid3.json")" "boom: disk full"
assert_eq "the failure does not duplicate the child's log as an error" \
    "$(jq -r 'has("error")' "$BKC/results/$bid3.json")" "false"
assert_eq "a failed backup's result never carries a passphrase field" \
    "$(jq -r 'has("passphrase")' "$BKC/results/$bid3.json")" "false"
assert_contains "the failed attempt is audited" \
    "$(cat "$BKC/audit/control.log")" '"action":"backup","status":"failed"'
unset BACKUP_FAIL

# Throttle (mirrors #59's upgrade throttle): bid1 above already claimed the 10-minute window —
# a fourth attempt right after is refused before the passphrase is even generated.
bid4="a0a0a0a0-0000-4000-8000-000000000004"
: >"$SELF_LOG"
printf '{"id":"%s","action":"backup","actor":"admin"}\n' "$bid4" >"$BKC/req4.json"
run_sourced_e "$SANDBOX" control_process_request "$BKC/req4.json" "$BKC" >/dev/null 2>&1
assert_contains "an immediate second backup attempt is throttled" \
    "$(jq -r .error "$BKC/results/$bid4.json")" "less than 10 minutes"
assert_eq "a throttled attempt never runs the child" "$(cat "$SELF_LOG")" ""

# The request schema itself cannot carry a passphrase — control_process_request's fixed key
# allowlist (id/action/config/actor/version/worker/changes/confirm) rejects any other field
# before the action even dispatches, so the container has no field to smuggle one through.
bid5="a0a0a0a0-0000-4000-8000-000000000005"
printf '{"id":"%s","action":"backup","actor":"admin","passphrase":"leaked"}\n' "$bid5" >"$BKC/req5.json"
run_sourced_e "$SANDBOX" control_process_request "$BKC/req5.json" "$BKC" >/dev/null 2>&1
assert_contains "a request carrying a passphrase field is refused outright (unexpected keys)" \
    "$(jq -r .error "$BKC/results/$bid5.json")" "unexpected keys"

# Backstop: a kit whose runner was KILLED mid-TTL keeps a plaintext passphrase on /data. The next
# drain's control_redact_stale_kits must null it once past the TTL, while leaving a still-in-window
# kit and a non-kit result alone.
export CONTROL_BACKUP_KIT_TTL_S=20 # cutoff = max(2x, 120) = 120s
old_ts=$(($(date +%s) - 3600))     # an hour stale
now_ts=$(date +%s)                 # fresh
jq -n --argjson t "$old_ts" '{status:"applied",passphrase:"STRANDED-SECRET",archive:"a.enc",ts:$t}' >"$BKC/results/stale.json"
jq -n --argjson t "$now_ts" '{status:"applied",passphrase:"LIVE-SECRET",archive:"b.enc",ts:$t}' >"$BKC/results/fresh.json"
jq -n --argjson t "$old_ts" '{status:"applied",change_id:"c",ts:$t}' >"$BKC/results/other.json" # not a kit
run_sourced "$SANDBOX" control_redact_stale_kits "$BKC/results" >/dev/null 2>&1
assert_eq "a stranded kit passphrase (runner died mid-TTL) is redacted on the next drain" \
    "$(jq -r '.passphrase // "null"' "$BKC/results/stale.json")" "null"
assert_eq "a kit still inside its window keeps its passphrase" \
    "$(jq -r '.passphrase' "$BKC/results/fresh.json")" "LIVE-SECRET"
assert_eq "a non-kit result is left untouched" \
    "$(jq -r '.change_id' "$BKC/results/other.json")" "c"
unset PITHEAD_SELF SELF_LOG PASS_LOG FAKE_ARCHIVE CONTROL_BACKUP_KIT_TTL_S bid1 bid2 bid3 bid4 bid5 pass1 old_ts now_ts

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
