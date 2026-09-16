# shellcheck shell=bash
: "${STACK_SUITE:?is unset: this file is a tests/stack/run.sh fragment, not a script — run tests/stack/run.sh}"
# Control-channel data-management domain (#1105 Phase 1, appliance lane): the sections that prove
# where a dashboard-confirmed data-dir move may point, and that the confirm gate does not tax the
# ordinary case. #719 made the *_DATA_DIR moves confirm-gated, but assert_safe_dir is a BLOCKLIST,
# so a confirmed move could still target any non-blocklisted absolute path; control_approval_gate
# narrows the DESTINATION to an allowlist for control-channel moves (#728). The second section is
# the other side of that bargain: a NON-destructive commit still proceeds with no token at all
# (#33), so the gate refuses the disruptive shape without gating everything.
# Sourced by tests/stack/run.sh.
#
# THIS FILE IS DELIBERATELY NOT STANDALONE-SOURCEABLE, AND THAT IS THE CORRECT CALL HERE.
# It follows the shipped add-only-ssrf disclosure precedent — source in place, position-locked,
# dependency disclosed here — rather than the self-arm pattern most domain files use. "It should
# self-arm like its neighbours" is the obvious review note and it is wrong for this domain:
#
# - This domain is a pure CONSUMER of the control sandbox. It never calls build_control_sandbox();
#   test-control-core.sh calls it once, in the control-core domain sourced ahead, and $C, $CTRL_LOG,
#   $SANDBOX and $WALLET reach here from it or from lib.sh.
#   (That section lived in run.sh until #1105 R12 moved it into its own domain file.)
# - This domain is position-locked by what it READS, not by anything a second builder call would
#   overwrite. Calling build_control_sandbox() here would be harmless, and that is why it buys
#   nothing: $C is the fixed path "$SANDBOX/control", its mkdir -p only creates, its copies are
#   static inputs, and seed_control_env/control_config are DEFINED inside it and never called — so
#   the builder writes no config.json and touches nothing under data/control/{requests,staged,
#   results,audit}. It could not establish the state this domain depends on, only running in
#   position after the sections that accumulate it can.
#   Its closing section reads back config state that the confirm-gate domain applied just before
#   it — a file-to-file dependency carried by $UUID3, which no builder call can supply.
#   The coupling that DOES bite here is write-side, and it has a recorded firing: the rig-worker
#   token-mask cluster moved with a re-derived $C, its applies wrote EXTRA result files into the
#   shared results dir, and a still-in-run.sh assertion counting that dir went red. That is
#   pollution of a counted directory — a different mechanism from anything being reset.
#   RETRACTED (#1105 R12): that firing's stated MECHANISM does not reproduce at the tip — the
#   apply path writes nothing into results/ unless is_appliance(), which no sandbox run
#   satisfies. The RED was real; WHY is not established, and the full re-derivation is in
#   test-rig-worker.sh's header. This domain's position-lock rests on what it READS, not on it.
#
# Re-derivations, audited over this WHOLE file, this header included. The audit script is
# lane-local and is NOT in this repo, so nothing below rests on it: each claim is written to be
# re-derived here with git and grep alone, and should be treated as a claim to check.
# - $REQS, $RESULTS and $STAGED are NOT the builder's. They are assigned by the control-run-pending
#   section, in test-control-core.sh, sourced before this stanza — an ordering dependency, same class
#   as any other. They are deliberately NOT seeded here: each is a plain derivation from $C, so a
#   seed would duplicate that file's definitions and could drift from them, and it would buy nothing,
#   because $C itself keeps this file non-standalone either way.
# - $WALLET is NOT a top-level constant. lib.sh assigns it only INSIDE the two sandbox builders, as
#   WALLET="${WALLET:-$VALID_PRIMARY}", and run.sh never assigns it at all — so it reaches this
#   domain from the same build_control_sandbox call that provides $C, by the same ordering
#   dependency, and belongs in the disclosure above rather than filed as a constant.
# - $SANDBOX and $VALID_TARI ARE lib.sh top-level constants, assigned at column one outside every
#   function. That distinction is the whole point of checking the column rather than trusting that
#   a name resolves to lib.sh at all.
# - $UUID3 IS INHERITED FROM test-confirm-approval.sh, which assigns it in ITS moved text and whose
#   stanza run.sh sources immediately before this one. This is a file-to-file dependency that the
#   split creates — it did not exist while both sections lived in run.sh — so it is disclosed on
#   both sides and guarded below. $UUID7 and $EVIL_DIR are assigned here, in the moved text.
# - THE DEPENDENCY IS ALSO IN FUNCTION FORM, not only in variables. control_config() is not a
#   top-level lib.sh function: it is defined INSIDE build_control_sandbox(), so it does not exist
#   until that builder has run. This domain calls it, which is a second, independent reason the
#   file cannot stand alone — and one a variable-only sweep cannot see. The other provider
#   functions it calls are top-level: assert_eq, assert_contains, assert_rc, run_pending,
#   run_sourced, and ok/bad beneath the assertions. It does NOT call seed_env or seed_control_env.
# - preview_move() is defined in the moved text and is not unset at its end, so it outlives the
#   source exactly as it outlived its old position in run.sh. No other file under tests/stack/
#   uses that name, so nothing downstream can see a definition it did not see before.
#
# The source stanza sits at this block's own vacated position, immediately after the confirm-gate
# domain it inherits $UUID3 from, so every assertion runs in the order it always ran. The anchor
# is a correctness requirement in this cut, not a preference.
#
# The guard below is the ambient contract made executable: sourced out of position, this file
# stops on a named variable instead of degrading into assertions against an unbuilt sandbox.
: "${C:?}" "${CTRL_LOG:?}" "${SANDBOX:?}" "${WALLET:?}" "${VALID_TARI:?}" "${UUID3:?}" "${REQS:?}" "${RESULTS:?}" "${STAGED:?}"

echo "== black-box: a dashboard-confirmed data-dir move is allowlisted to the stack data root (#728) =="
# #719/#1959 made the five configured *_DATA_DIR moves confirm-gated. assert_safe_dir is a BLOCKLIST, so a
# confirmed move could target any non-blocklisted absolute path (another user's home, another
# service's volume). control_approval_gate now narrows the DESTINATION to an allowlist for
# control-channel moves: only under the stack data root ($C/data) or the dedicated parent shared by
# Monero, Tari, P2Pool, and Tor.
# The host `apply` path keeps the blocklist — a shell operator is already trusted.
UUID7="77777777-7777-4777-8777-777777777777"
control_config mini
(cd "$C" && DOCKER_LOG="$CTRL_LOG" PATH="$C/bin:$PATH" ./pithead apply -y >/dev/null 2>&1)
EVIL_DIR="$SANDBOX/other-service-vol/monero" # absolute, NOT blocklisted, NOT under $C/data
preview_move() {                             # <monero.data_dir>
    jq -n --arg w "$WALLET" --arg id "$UUID7" --arg dd "$1" '{id:$id,action:"preview",actor:"admin",config:{
        monero:{mode:"local",wallet_address:$w,node_username:"u",node_password:"p",data_dir:$dd},
        tari:{wallet_address:"'"$VALID_TARI"'"}, p2pool:{pool:"mini"},
        dashboard:{secure:true,host:"box.lan",auth:{username:"admin",password:"a control passphrase"},control:{enabled:true}}}}' >"$REQS/$UUID7.json"
    run_pending >/dev/null
}
preview_dashboard_move() { # <dashboard.data_dir>
    jq -n --slurpfile live "$C/config.json" --arg id "$UUID7" --arg dd "$1" \
        '{id:$id,action:"preview",actor:"admin",config:($live[0] | .dashboard.data_dir=$dd)}' >"$REQS/$UUID7.json"
    run_pending >/dev/null
}
# (1) A move UNDER the stack data root, confirmed with APPLY, is allowed and lands.
preview_move "$C/data/monero-v2"
assert_contains "in-root data-dir move previews a CONFIRM row" "$(jq -r '.changes[].flag' "$RESULTS/$UUID7.json" 2>/dev/null)" "CONFIRM"
printf '{"id":"%s","action":"commit","actor":"admin","confirm":"APPLY"}\n' "$UUID7" >"$REQS/$UUID7.json"
run_pending >/dev/null
assert_eq "in-root data-dir move with APPLY applies" "$(jq -r '.status' "$RESULTS/$UUID7.json" 2>/dev/null)" "applied"
assert_eq "in-root move landed in .env" "$(run_sourced "$C" env_get_file "$C/.env" MONERO_DATA_DIR)" "$C/data/monero-v2"
# (2) A move to an arbitrary non-blocklisted, non-allowed path is refused EVEN with APPLY.
preview_move "$EVIL_DIR"
printf '{"id":"%s","action":"commit","actor":"admin","confirm":"APPLY"}\n' "$UUID7" >"$REQS/$UUID7.json"
run_pending >/dev/null
assert_eq "out-of-root data-dir move is refused despite the APPLY token" "$(jq -r '.status' "$RESULTS/$UUID7.json" 2>/dev/null)" "rejected"
assert_contains "refusal names the data-root allowlist" "$(jq -r '.error' "$RESULTS/$UUID7.json" 2>/dev/null)" "outside the stack data root"
# The refusal left config.json untouched — it still carries the previously-committed in-root value
# (test 1), never the refused out-of-root path.
assert_eq "refused move did not touch config.json" "$(jq -r '.monero.data_dir // empty' "$C/config.json")" "$C/data/monero-v2"
[ ! -f "$STAGED/$UUID7.json" ] && ok "refused out-of-root move cleared from staged" || bad "refused out-of-root move cleared from staged" "still staged"
# Tor joined the fallback confirm tier in #1959 and must receive the same destination guard.
jq -n --slurpfile live "$C/config.json" --arg id "$UUID7" --arg dd "$EVIL_DIR" \
    '{id:$id,action:"preview",actor:"admin",config:($live[0] | .tor.data_dir=$dd)}' >"$REQS/$UUID7.json"
run_pending >/dev/null
jq -n --arg id "$UUID7" '{id:$id,action:"commit",actor:"admin",confirm:"APPLY",approval:{payout_suffixes:{}}}' >"$REQS/$UUID7.json"
run_pending >/dev/null
assert_eq "out-of-root Tor data-dir move is refused" "$(jq -r '.status' "$RESULTS/$UUID7.json")" "rejected"
assert_contains "Tor move uses the data-root allowlist" "$(jq -r '.error' "$RESULTS/$UUID7.json")" "outside the stack data root"
# (3) A destination below any dashboard-writable host directory is refused even when its current
# symlink target is inside the allowlist. Otherwise the container could swap that ancestor to an
# arbitrary host path after validation but before root-owned mkdir/chown.
DASHBOARD_ROOT="$(run_sourced "$C" env_get_file "$C/.env" DASHBOARD_DATA_DIR)"
CONTROL_ROOT="$(run_sourced "$C" env_get_file "$C/.env" CONTROL_DIR)"
CLEARNET_ROOT="$(run_sourced "$C" env_get_file "$C/.env" CLEARNET_STATE_DIR)"
mkdir -p "$DASHBOARD_ROOT" "$CONTROL_ROOT/requests" "$CLEARNET_ROOT" "$C/data/symlink-target"
WRITABLE_CASE=0
for WRITABLE_ROOT in "$DASHBOARD_ROOT" "$CONTROL_ROOT/requests" "$CLEARNET_ROOT"; do
    WRITABLE_CASE=$((WRITABLE_CASE + 1))
    ln -s "$C/data/symlink-target" "$WRITABLE_ROOT/pivot"
    preview_move "$WRITABLE_ROOT/pivot/monero"
    printf '{"id":"%s","action":"commit","actor":"admin","confirm":"APPLY"}\n' "$UUID7" >"$REQS/$UUID7.json"
    run_pending >/dev/null
    assert_eq "dashboard-writable ancestor $WRITABLE_CASE is refused despite APPLY" \
        "$(jq -r '.status' "$RESULTS/$UUID7.json" 2>/dev/null)" "rejected"
    assert_contains "writable-ancestor $WRITABLE_CASE refusal names the boundary" \
        "$(jq -r '.error' "$RESULTS/$UUID7.json" 2>/dev/null)" "dashboard-writable"
    rm -f "$WRITABLE_ROOT/pivot"
done
# The rest of the control spool is host-only but also cannot become service data.
preview_move "$CONTROL_ROOT/results/monero"
printf '{"id":"%s","action":"commit","actor":"admin","confirm":"APPLY"}\n' "$UUID7" >"$REQS/$UUID7.json"
run_pending >/dev/null
assert_eq "internal control directory is refused despite the APPLY token" \
    "$(jq -r '.status' "$RESULTS/$UUID7.json" 2>/dev/null)" "rejected"
assert_contains "internal control refusal names the boundary" \
    "$(jq -r '.error' "$RESULTS/$UUID7.json" 2>/dev/null)" "internal or dashboard-writable"
# Mounting the shared parent would expose every sibling to the dashboard. A cross-over with a live
# service remains forbidden even if the same candidate moves that service elsewhere.
preview_dashboard_move "$C/data"
printf '{"id":"%s","action":"commit","actor":"admin","confirm":"APPLY"}\n' "$UUID7" >"$REQS/$UUID7.json"
run_pending >/dev/null
assert_eq "dashboard cannot mount the shared data ancestor" \
    "$(jq -r '.status' "$RESULTS/$UUID7.json")" "rejected"
assert_contains "shared data ancestor refusal names the overlap" \
    "$(jq -r '.error' "$RESULTS/$UUID7.json")" "overlap"
TOR_ROOT="$(run_sourced "$C" env_get_file "$C/.env" TOR_DATA_DIR)"
jq -n --slurpfile live "$C/config.json" --arg id "$UUID7" --arg old "$TOR_ROOT" --arg new "$C/data/tor-v2" \
    '{id:$id,action:"preview",actor:"admin",config:($live[0] | .dashboard.data_dir=$old | .tor.data_dir=$new)}' >"$REQS/$UUID7.json"
run_pending >/dev/null
printf '{"id":"%s","action":"commit","actor":"admin","confirm":"APPLY"}\n' "$UUID7" >"$REQS/$UUID7.json"
run_pending >/dev/null
assert_eq "dashboard cannot take a live service directory while repointing it" \
    "$(jq -r '.status' "$RESULTS/$UUID7.json")" "rejected"
assert_contains "live service cross-over names the protected root" \
    "$(jq -r '.error' "$RESULTS/$UUID7.json")" "live.tor"

# Internal log and TLS roots are siblings under the allowlisted data parent, but never service data.
for INTERNAL_ROOT in "$(run_sourced "$C" env_get_file "$C/.env" CADDY_LOG_DIR)" \
    "$(run_sourced "$C" env_get_file "$C/.env" PROXY_TLS_DIR)"; do
    preview_move "$INTERNAL_ROOT/monero"
    printf '{"id":"%s","action":"commit","actor":"admin","confirm":"APPLY"}\n' "$UUID7" >"$REQS/$UUID7.json"
    run_pending >/dev/null
    assert_eq "internal log/TLS root is refused" "$(jq -r '.status' "$RESULTS/$UUID7.json")" "rejected"
done

# Older .env files lack newer internal-root keys; the runtime defaults remain protected.
cp "$C/.env" "$C/.env.with-internal-roots"
sed -E '/^(CONTROL_DIR|CLEARNET_STATE_DIR)=/d' "$C/.env.with-internal-roots" >"$C/.env"
for INTERNAL_ROOT in "$C/data/control" "$C/data/clearnet-state"; do
    preview_move "$INTERNAL_ROOT/monero"
    printf '{"id":"%s","action":"commit","actor":"admin","confirm":"APPLY"}\n' "$UUID7" >"$REQS/$UUID7.json"
    run_pending >/dev/null
    assert_eq "missing env key does not unprotect the runtime root" \
        "$(jq -r '.status' "$RESULTS/$UUID7.json")" "rejected"
done
mv "$C/.env.with-internal-roots" "$C/.env"
if [ ! -e "$C/data/symlink-target/monero" ]; then
    ok "refused symlinked move touched no target"
else
    bad "refused symlinked move touched no target" "target exists"
fi
# (4) Co-location under a broad system root does not authorize its sibling services.
cp "$C/.env" "$C/.env.before-broad-root"
sed -E \
    -e 's|^MONERO_DATA_DIR=.*|MONERO_DATA_DIR=/var/lib/monero|' \
    -e 's|^TARI_DATA_DIR=.*|TARI_DATA_DIR=/var/lib/tari|' \
    -e 's|^P2POOL_DATA_DIR=.*|P2POOL_DATA_DIR=/var/lib/p2pool|' \
    -e 's|^TOR_DATA_DIR=.*|TOR_DATA_DIR=/var/lib/tor|' \
    "$C/.env.before-broad-root" >"$C/.env"
preview_move "/var/lib/docker"
printf '{"id":"%s","action":"commit","actor":"admin","confirm":"APPLY"}\n' "$UUID7" >"$REQS/$UUID7.json"
run_pending >/dev/null
assert_eq "broad shared parent is refused despite the APPLY token" \
    "$(jq -r '.status' "$RESULTS/$UUID7.json")" "rejected"
assert_contains "broad shared parent does not widen the allowlist" \
    "$(jq -r '.error' "$RESULTS/$UUID7.json")" "outside the stack data root"
mv "$C/.env.before-broad-root" "$C/.env"
# (5) The SAME path from the HOST shell still applies — the tighter rule is control-only.
jq -n --arg w "$WALLET" --arg dd "$EVIL_DIR" '{monero:{mode:"local",wallet_address:$w,node_username:"u",node_password:"p",data_dir:$dd},
    tari:{wallet_address:"'"$VALID_TARI"'"}, p2pool:{pool:"mini"},
    dashboard:{secure:true,host:"box.lan",auth:{username:"admin",password:"a control passphrase"},control:{enabled:true}}}' >"$C/config.json"
(cd "$C" && DOCKER_LOG="$CTRL_LOG" PATH="$C/bin:$PATH" ./pithead apply -y >/dev/null 2>&1)
assert_rc "host-shell apply to the same out-of-root path succeeds" "$?" "0"
assert_eq "host-shell apply rendered the out-of-root path (blocklist, not allowlist)" "$(run_sourced "$C" env_get_file "$C/.env" MONERO_DATA_DIR)" "$EVIL_DIR"

echo "== black-box: a NON-destructive commit still proceeds with no token (#33) =="
# Restore a clean baseline (prune off, clearnet off) then a pool switch mini -> nano is INFO, not
# DEST/CONFIRM — it commits with no confirmation at all.
control_config mini
(cd "$C" && DOCKER_LOG="$CTRL_LOG" PATH="$C/bin:$PATH" ./pithead apply -y >/dev/null 2>&1)
jq -n --arg w "$WALLET" --arg id "$UUID3" '{id:$id,action:"preview",actor:"admin",config:{
    monero:{mode:"local",wallet_address:$w,node_username:"u",node_password:"p"},
    tari:{wallet_address:"'"$VALID_TARI"'"}, p2pool:{pool:"nano"},
    dashboard:{secure:true,host:"box.lan",auth:{username:"admin",password:"a control passphrase"},control:{enabled:true}}}}' >"$REQS/$UUID3.json"
run_pending >/dev/null
printf '{"id":"%s","action":"commit","actor":"admin"}\n' "$UUID3" >"$REQS/$UUID3.json"
run_pending >/dev/null
assert_eq "non-destructive commit still applies through the gate" "$(jq -r '.status' "$RESULTS/$UUID3.json" 2>/dev/null)" "applied"
assert_eq "non-destructive change landed in config.json" "$(jq -r '.p2pool.pool' "$C/config.json")" "nano"
