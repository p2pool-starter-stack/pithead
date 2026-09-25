# shellcheck shell=bash
: "${STACK_SUITE:?is unset: this file is a tests/stack/run.sh fragment, not a script — run tests/stack/run.sh}"
# Appliance setup domain (#1105 Phase 1, appliance lane): the firstboot provisioning path an
# appliance walks the first time it is powered on, and the uninstall contract that path has to
# survive — the wizard's minted pairing token and its spool consume (#77 phase 3), and the
# black-box guarantee that `uninstall` removes only what the stack rendered and keeps the
# operator's own files (#77 phase 1). The restore-at-setup leg (firstboot_consume_restore) is a
# different behaviour boundary and lives in test-appliance-restore.sh (#2195).
# Sourced by tests/stack/run.sh.
#
# Re-derivations:
# - $V, $WALLET and seed_env(): all three are lib.sh's build_val_sandbox() — $V and $WALLET as
#   globals, seed_env() as a function defined inside that builder's body, so it does not exist
#   until the builder has run. In run.sh these arrived ambiently from the far-earlier config and
#   dashboard domains, which call the builder for their own reasons; neither is an appliance-setup
#   concern, so this file self-arms instead of inheriting. build_val_sandbox() is idempotent — a
#   fixed $SANDBOX/val path, mkdir -p, and template copies, with no removal of the .env or
#   config.json this domain writes — so the call is a safe re-affirm as currently sourced, and it
#   is what makes the file sourceable standalone under `set -u`.
# - The neighbouring warning against this exact call, and why it does not reach it.
#   test-doctor-appliance.sh — sourced one stanza above this file — warns explicitly against
#   calling build_val_sandbox() again, because doing so would reset the shared "$SANDBOX/val" out
#   from under the config-validation / dashboard / payout sections that were still threaded through
#   run.sh when that comment was written; it mirrors the builder's body under a non-colliding name
#   instead. That warning is about CLOBBERING A NEIGHBOUR, and it does not reach this call: every
#   domain file sourced after this one that reads $V or seed_env() outside a comment self-arms at
#   its own entry, and the builder writes neither the .env nor the config.json this domain writes.
#   It is cited here rather than left implicit because "idempotent" is the word a future author
#   will reuse without re-running that audit, and a build_val_sandbox call placed elsewhere in this
#   neighbourhood could genuinely clobber, exactly as that warning says.
# - $VALID_TARI is a plain lib.sh top-level constant, not build_val_sandbox()-scoped, so it needs
#   no arming here.
# - $SANDBOX, $ROOT and $STACK are lib.sh top-level globals, as are the assertion helpers this
#   domain calls (assert_eq, assert_rc, assert_contains, ok, bad) and run_sourced.
# - The uninstall section closes by re-rendering the sandbox .env and config.json, because
#   `uninstall -y` has just deleted them. That tail is retained here verbatim rather than dropped:
#   the source stanza sits at this block's exact former position in run.sh, so the re-render still
#   precedes exactly the successors it preceded before, and execution order is unchanged by the
#   move. Relocating the stanza would make that tail a live ordering decision rather than a
#   no-op, which is why the anchor is the block's own vacated position.
build_val_sandbox

echo "== unit: firstboot wizard token + spool consume (#77 phase 3) =="
# Token: pit- prefix + 6 chars from the unambiguous alphabet (never 0, O, 1, I, or l).
tok=$(run_sourced "$SANDBOX" wizard_mint_token)
assert_eq "token shape" "$(printf '%s' "$tok" | grep -cE '^pit-[23456789ABCDEFGHJKMNPQRSTUVWXYZ]{6}$')" "1"
tok2=$(run_sourced "$SANDBOX" wizard_mint_token)
assert_eq "tokens vary" "$([ "$tok" = "$tok2" ] && echo same || echo differ)" "differ"
# Consume: a valid submission installs config.json + marks applied; an invalid one surfaces the
# error into the spool for the form and installs nothing; an empty spool is rc 2.
WSPOOL="$V/data/firstboot-test"
mkdir -p "$WSPOOL"
rm -f "$V/config.json"
printf '{ "monero": {"wallet_address":"%s"}, "tari":{"wallet_address":"'"$VALID_TARI"'"}, "p2pool":{"pool":"mini","stratum_password":"auto"}, "dashboard":{"workers":[{"name":"legacy-rig","token":"fixture-secret"}]} }\n' "$WALLET" >"$WSPOOL/config.json"
out=$(cd "$V" && PATH="$V/bin:$PATH" run_sourced "$V" firstboot_consume_spool "$WSPOOL" && echo rc0)
assert_contains "valid submission accepted" "$out" "rc0"
assert_eq "valid submission installs config.json" "$([ -f "$V/config.json" ] && echo yes)" "yes"
assert_eq "applied marker set" "$([ -f "$WSPOOL/applied" ] && echo yes)" "yes"
assert_eq "wizard validation snapshot leaves no migration backup" "$(find "$WSPOOL" -name '*.bak-1x' -print -quit)" ""
rm -f "$WSPOOL/applied"
printf '{ "monero": {"wallet_address":"8-not-a-primary"}, "tari":{"wallet_address":"'"$VALID_TARI"'"}, "p2pool":{"pool":"mini"} }\n' >"$WSPOOL/config.json"
out=$(cd "$V" && PATH="$V/bin:$PATH" run_sourced "$V" firstboot_consume_spool "$WSPOOL" || echo "rc$?")
assert_contains "invalid submission rejected" "$out" "rc1"
assert_eq "rejection surfaces spool error" "$([ -s "$WSPOOL/error.txt" ] && echo yes)" "yes"
assert_eq "rejection leaves no candidate" "$([ -f "$WSPOOL/config.json" ] || echo gone)" "gone"
out=$(run_sourced "$V" firstboot_consume_spool "$WSPOOL" || echo "rc$?")
assert_contains "empty spool is rc2" "$out" "rc2"
rm -rf "$WSPOOL"
# Restore the sandbox config for later sections.
printf '{ "monero": {"mode":"local","wallet_address":"%s","node_username":"u","node_password":"p"}, "tari":{"wallet_address":"'"$VALID_TARI"'"}, "p2pool":{"pool":"main"}, "dashboard":{"secure":true,"host":"box.lan"} }\n' "$WALLET" >"$V/config.json"
# A missing env file is a hard error, not an empty render.
out=$(run_sourced "$SANDBOX" render_quadlet_units "$SANDBOX/no-such.env" "$SANDBOX/quadlet-none" 2>&1)
assert_contains "render-quadlet missing env errors" "$out" "env file not found"

echo "== black-box: uninstall keeps every byte of data and prints the three-column inventory (#2379, #77 phase 1) =="
# Self-provision a fully-rendered .env rather than relying on an earlier section's ambient one:
# this used to inherit it for free from the dashboard-auth-lifecycle black-box, which ran
# immediately before this section in the original file; that test now lives in
# test-dashboard.sh (#1105 Phase 1), sourced far earlier, so a LATER config-validation case
# (a rejected apply, whose own seed_env leaves .env at the bare pre-render baseline — no
# *_DATA_DIR keys) was the last thing to touch .env by the time this section ran. stack_uninstall
# greps .env for those keys with `pipefail` under `set -e`; zero matches makes that grep — not
# uninstall's own logic — abort the whole script. Render a real, complete .env here so this
# section proves uninstall's OWN behaviour instead of depending on a same-file predecessor.
seed_env
printf '{ "monero": {"mode":"local","wallet_address":"%s","node_username":"u","node_password":"p"}, "tari":{"wallet_address":"'"$VALID_TARI"'"}, "p2pool":{"pool":"main"}, "dashboard":{"secure":true,"host":"box.lan"} }\n' "$WALLET" >"$V/config.json"
kept_dir="$V/"'kept $literal'
jq --arg dir "$kept_dir" '.monero.data_dir = $dir' "$V/config.json" >"$V/config.json.tmp" && mv "$V/config.json.tmp" "$V/config.json"
out="$(cd "$V" && PATH="$V/bin:$PATH" ./pithead apply -y 2>&1)"
rc=$?
assert_rc "uninstall fixture: self-provisioned apply succeeds" "$rc" "0"
# apply's ensure_directories/prepare_control_dirs/inject_service_configs create every derived
# state dir unconditionally (#2379 §3), regardless of which chain/TLS flags the fixture config
# sets — sanity-check that before trusting the removal assertions below.
missing_derived=""
for d in data/control data/clearnet-state data/caddy-logs data/proxy-tls; do
    [ -d "$V/$d" ] || missing_derived="$missing_derived $d"
done
assert_eq "uninstall fixture: apply created every derived state dir" "$missing_derived" ""
: >"$V/data/tari-wallet-secret.env" # apply only populates this with a Tari view key configured; force it present for the test

# Drop a marker into every kept path so "byte-identical before/after" is provable, not assumed.
mkdir -p "$V/backups"
kept_markers=("$V/config.json" "$V/backups/marker.txt" "$kept_dir/marker.txt" "$V/data/tari/marker.txt" "$V/data/p2pool/marker.txt" "$V/data/tor/marker.txt" "$V/data/dashboard/marker.txt")
for f in "${kept_markers[@]}"; do
    [ -f "$f" ] || { mkdir -p "$(dirname "$f")" && printf 'marker' >"$f"; }
done
hash_kept() { for f in "${kept_markers[@]}"; do sha256sum "$f" 2>/dev/null || shasum -a 256 "$f"; done; }
hash_before="$(hash_kept)"

# Without confirmation: aborts, changes nothing.
touch "$V/Caddyfile"
out=$(cd "$V" && printf 'no\n' | PATH="$V/bin:$PATH" ./pithead uninstall 2>&1) || true
assert_contains "uninstall aborts without the confirm word" "$out" "Aborted"
assert_eq "aborted uninstall keeps .env" "$([ -f "$V/.env" ] && echo yes)" "yes"
# Uninstall removes the control-runner units, so it joins the shared window like apply does. Hold
# the window and prove uninstall refuses before its first destructive step.
UNINSTALL_LOCK="$V/uninstall-held.lock"
DOCKER_LOG="$V/docker.log"
: >"$DOCKER_LOG"
(
    exec 9>>"$UNINSTALL_LOCK"
    flock 9
    exec sleep 30
) &
UNINSTALL_HOLDER=$!
uninstall_lock_held() { ! flock -n "$UNINSTALL_LOCK" true 2>/dev/null; }
wait_while_alive "$UNINSTALL_HOLDER" uninstall_lock_held
assert_rc "uninstall contention fixture holds the mutation window" "$?" "0"
rc=0
out=$(cd "$V" && DOCKER_LOG="$DOCKER_LOG" PITHEAD_LOCK_FILE="$UNINSTALL_LOCK" PITHEAD_LOCK_TIMEOUT=1 \
    PATH="$V/bin:$PATH" ./pithead uninstall -y 2>&1) || rc=$?
assert_contains "uninstall waits on the same mutation window as apply" "$out" "Timed out after 1s"
assert_not_contains "a contended uninstall never reaches container removal" "$(cat "$DOCKER_LOG" 2>/dev/null)" "compose down"
assert_eq "a contended uninstall changes nothing" "$([ -f "$V/.env" ] && echo yes)" "yes"
kill "$UNINSTALL_HOLDER" 2>/dev/null || true
wait "$UNINSTALL_HOLDER" 2>/dev/null || true
unset UNINSTALL_LOCK UNINSTALL_HOLDER rc
unset -f uninstall_lock_held
UNINSTALL_UNITS="$V/uninstall-units"
mkdir -p "$UNINSTALL_UNITS"
printf '[Service]\nExecStart=%s/pithead control-run-pending\n' "$(cd "$V" && pwd -P)" >"$UNINSTALL_UNITS/pithead-control.service"
printf '[Path]\nPathExistsGlob=%s/data/control/requests/*.json\n' "$(cd "$V" && pwd -P)" >"$UNINSTALL_UNITS/pithead-control.path"
printf '#!/usr/bin/env bash\nexit 0\n' >"$V/bin/systemctl"
cat >"$V/bin/sudo" <<'SUDOEOF'
#!/usr/bin/env bash
[ "$1" = rm ] && { shift; exec rm "$@"; }
exit 0
SUDOEOF
chmod +x "$V/bin/systemctl" "$V/bin/sudo"

# With -y: the three columns print, the named volumes go with `compose down -v`, every
# pithead-derived path is removed, and every kept path survives byte-identical.
: >"$DOCKER_LOG"
out=$(cd "$V" && DOCKER_LOG="$DOCKER_LOG" PITHEAD_UNIT_DIR="$UNINSTALL_UNITS" PATH="$V/bin:$PATH" ./pithead uninstall -y 2>&1)
assert_contains "uninstall states the removed column" "$out" "Removed:"
assert_contains "uninstall states the kept column" "$out" "Kept (yours):"
assert_contains "uninstall states the left-behind column" "$out" "Left behind"
assert_contains "uninstall names the kept files" "$out" "config.json"
assert_contains "uninstall displays the decoded data path" "$out" "$kept_dir"
assert_contains "uninstall names the three volumes it removes with the containers" "$out" "caddy_data/wallet_data/tari_wallet_data"
assert_contains "uninstall prints the removal command" "$out" "sudo rm -rf"
assert_contains "uninstall's removal command quotes a path with a space" "$out" "'$kept_dir'"
assert_eq "uninstall compose-downs with -v so the named volumes go with the containers" \
    "$(grep -Fc 'compose down --remove-orphans -v' "$DOCKER_LOG" 2>/dev/null | tr -d '[:space:]')" "1"
assert_eq "uninstall removes .env" "$([ -f "$V/.env" ] || echo gone)" "gone"
assert_eq "uninstall removes Caddyfile" "$([ -f "$V/Caddyfile" ] || echo gone)" "gone"
assert_eq "uninstall removes the rendered Tari config" "$([ -f "$V/build/tari/config.toml" ] || echo gone)" "gone"
assert_eq "uninstall removes the control spool" "$([ -d "$V/data/control" ] || echo gone)" "gone"
assert_eq "uninstall removes the clearnet-state dir" "$([ -d "$V/data/clearnet-state" ] || echo gone)" "gone"
assert_eq "uninstall removes the Caddy access-log dir" "$([ -d "$V/data/caddy-logs" ] || echo gone)" "gone"
assert_eq "uninstall removes the stratum TLS dir" "$([ -d "$V/data/proxy-tls" ] || echo gone)" "gone"
assert_eq "uninstall removes the Tari wallet secret file" "$([ -f "$V/data/tari-wallet-secret.env" ] || echo gone)" "gone"
assert_eq "uninstall keeps config.json" "$([ -f "$V/config.json" ] && echo yes)" "yes"
assert_eq "uninstall keeps backups/" "$([ -d "$V/backups" ] && echo yes)" "yes"
assert_eq "uninstall keeps every *_DATA_DIR byte-identical (hash before == after)" "$(hash_kept)" "$hash_before"
assert_eq "uninstall removes its owned control-runner units" "$(find "$UNINSTALL_UNITS" -type f -print -quit)" ""
out=$(cd "$V" && PATH="$V/bin:$PATH" ./pithead uninstall --bogus 2>&1) || true
assert_contains "uninstall rejects unknown options" "$out" "Unknown option"
# Re-render the sandbox .env for the sections below — uninstall just deleted it.
make_stubs "$V/bin"
rm -f "$V/bin/systemctl"
unset UNINSTALL_UNITS
seed_env
printf '{ "monero": {"mode":"local","wallet_address":"%s","node_username":"u","node_password":"p"}, "tari":{"wallet_address":"'"$VALID_TARI"'"}, "p2pool":{"pool":"main"}, "dashboard":{"secure":true,"host":"box.lan"} }\n' "$WALLET" >"$V/config.json"
out="$(cd "$V" && PATH="$V/bin:$PATH" ./pithead apply -y 2>&1)"
# A derived key an operator pointed at the data root is refused, never `rm -rf`'d: .env is
# editable, and no edit may turn uninstall into the removal of the chains under it.
grep -v '^CONTROL_DIR=\|^CLEARNET_STATE_DIR=' "$V/.env" >"$V/.env.tmp" && mv "$V/.env.tmp" "$V/.env"
printf 'CONTROL_DIR=%s\nCLEARNET_STATE_DIR=%s\n' "$V/data" "$SANDBOX/elsewhere/clearnet-state" >>"$V/.env"
mkdir -p "$V/data/tari" "$SANDBOX/elsewhere/clearnet-state" && printf 'marker' >"$V/data/tari/guard.txt"
printf 'marker' >"$SANDBOX/elsewhere/clearnet-state/guard.txt"
# The runner drain inside uninstall reads CONTROL_DIR from .env, not the default spelling: a
# stale claim left under the default spelling must not hold uninstall for the 30-second bound.
UNINSTALL_UNITS="$V/uninstall-units"
mkdir -p "$UNINSTALL_UNITS" "$V/data/control"
printf '[Service]\nExecStart=%s/pithead control-run-pending\n' "$(cd "$V" && pwd -P)" >"$UNINSTALL_UNITS/pithead-control.service"
printf '#!/usr/bin/env bash\nexit 0\n' >"$V/bin/systemctl"
chmod +x "$V/bin/systemctl"
: >"$V/data/control/.claim.1"
SECONDS=0
out=$(cd "$V" && PITHEAD_UNIT_DIR="$UNINSTALL_UNITS" PATH="$V/bin:$PATH" ./pithead uninstall -y 2>&1)
assert_eq "uninstall drains the runner in the CONTROL_DIR restored from .env" "$([ "$SECONDS" -lt 20 ] && echo prompt || echo "waited ${SECONDS}s")" "prompt"
rm -rf "$UNINSTALL_UNITS" "$V/bin/systemctl" "$V/data/control/.claim.1"
unset UNINSTALL_UNITS
assert_contains "uninstall refuses a derived key that points at the data root" "$out" "Not removing CONTROL_DIR="
assert_eq "uninstall keeps the data root a derived key points at" "$(cat "$V/data/tari/guard.txt" 2>/dev/null)" "marker"
assert_eq "uninstall keeps a derived-named dir outside the path setup gives it" \
    "$(cat "$SANDBOX/elsewhere/clearnet-state/guard.txt" 2>/dev/null)" "marker"
seed_env
printf '{ "monero": {"mode":"local","wallet_address":"%s","node_username":"u","node_password":"p"}, "tari":{"wallet_address":"'"$VALID_TARI"'"}, "p2pool":{"pool":"main"}, "dashboard":{"secure":true,"host":"box.lan"} }\n' "$WALLET" >"$V/config.json"
out="$(cd "$V" && PATH="$V/bin:$PATH" ./pithead apply -y 2>&1)"

echo "== unit: a failed wizard setup hands back a machine that can be re-provisioned (#2050) =="
# setup's second render_env writes DEPLOYMENT_COMPLETED=true about a third of the way in — long
# before provision_control_runner, generate_caddyfile or the `up` that finishes it. Every failure
# past that point left the marker standing on a machine that is NOT deployed, so the retry
# wizard_keep_failed_config exists to enable could never run: setup's own is_deployed guard
# refuses headless with "Already provisioned … run from a terminal" (#924), and the reopened page
# died on that same refusal however the operator corrected their answers. Same marker, same
# reason, and the same clear restore_apply already makes on the carried-.env door (#1239).
WKFD="$SANDBOX/wizard-failed-deploy"
wkfd_reset() { # writes a machine-role so the keep takes the KEEP branch, not the re-arm one
    rm -rf "$WKFD"
    mkdir -p "$WKFD"
    cp "$STACK" "$WKFD/pithead"
    printf '{"submitted":"the operator answers"}\n' >"$WKFD/config.json"
    printf 'pithead\n' >"$WKFD/machine-role"
}
# A SECOND true-valued key beside the marker, so the substitution is pinned to the one it means:
# a blanket s/true/false/ would also flip DASHBOARD_SECURE and still pass a marker-only assertion
# while silently downgrading the machine to plain HTTP.
wkfd_reset
printf 'DASHBOARD_SECURE=true\nDEPLOYMENT_COMPLETED=true\nHOST_IP=10.0.0.2\n' >"$WKFD/.env"
run_sourced "$WKFD" wizard_keep_failed_config >/dev/null 2>&1
assert_rc "the keep still reports success while clearing the marker" "$?" "0"
# The arming control. rc 0 is also what a fixture that never ran returns from a subshell that died
# before reaching the function, and every assertion below would then pass or fail for a reason
# that has nothing to do with the clear. The kept copy is the function's other observable effect,
# so its presence is what says the body actually executed.
assert_eq "the fixture armed — the function ran and kept its copy" \
    "$([ -f "$WKFD/config.json.failed" ] && echo ran)" "ran"
assert_eq "a failed setup clears the deployment marker so a retry can provision" \
    "$(grep '^DEPLOYMENT_COMPLETED=' "$WKFD/.env")" "DEPLOYMENT_COMPLETED=false"
assert_eq "and touches no other key that happens to say true" \
    "$(grep '^DASHBOARD_SECURE=' "$WKFD/.env")" "DASHBOARD_SECURE=true"
# The negative half: nothing to clear must also mean nothing to create. An .env conjured here
# would hold only DEPLOYMENT_COMPLETED=false, which the required-key reads (#1246) treat as a
# corrupt file rather than the absent one it really is.
wkfd_reset
run_sourced "$WKFD" wizard_keep_failed_config >/dev/null 2>&1
assert_rc "the keep succeeds on a machine that never rendered an .env" "$?" "0"
assert_eq "no .env is created by the failure path" "$([ -e "$WKFD/.env" ] || echo absent)" "absent"
rm -rf "$WKFD"
