# shellcheck shell=bash
: "${STACK_SUITE:?is unset: this file is a tests/stack/run.sh fragment, not a script — run tests/stack/run.sh}"
# Dashboard data moves are confined to the stack data root; host operations retain their contract.
# The shared fixture seeds fresh processes and preserves existing config and spool state.

ensure_control_fixture

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
    assert_eq "dashboard-writable ancestor is refused despite APPLY" \
        "$(jq -r '.status' "$RESULTS/$UUID7.json" 2>/dev/null)" "rejected"
    assert_contains "writable-ancestor refusal names the boundary" \
        "$(jq -r '.error' "$RESULTS/$UUID7.json" 2>/dev/null)" "overlap"
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
preview_dashboard_move "$C/data/dashboard-v2"
assert_contains "dashboard move preview says apply carries the database (#2360)" \
    "$(jq -r '.changes[] | select(.flag == "CONFIRM") | .msg' "$RESULTS/$UUID7.json")" "copied there and verified, and the old copy stays in place"
assert_eq "a first dashboard.data_dir render promises no carry" \
    "$(run_sourced "$C" describe_change DASHBOARD_DATA_DIR "" "$C/data/dashboard")" \
    "CONFIRM	DASHBOARD_DATA_DIR: unset → $C/data/dashboard — the dashboard keeps its database here."
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
    "$(run_sourced "$C" env_get_file "$C/.env" PROXY_TLS_DIR)" \
    "$(run_sourced "$C" env_get_file "$C/.env" PITHEAD_TLS_DIR)"; do
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
