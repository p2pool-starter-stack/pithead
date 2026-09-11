# shellcheck shell=bash
: "${STACK_SUITE:?is unset: this file is a tests/stack/run.sh fragment, not a script — run tests/stack/run.sh}"
# Every key on CONTROL_DASHBOARD_EDITABLE_KEYS must actually round-trip a real preview->commit
# through the approval gate and land in config.json (#522) — not just pass a describe_change unit
# check. Split out of run.sh by #1105 R14; the section's own contract is stated at its header below.
#
# WHY THE CONTROL FAMILY, AND NOT THE CONFIG FAMILY THE CUT MAP GUESSED. The map homed this row
# with the config family on the strength of its subject: it flips config keys and reads them back
# out of config.json. Its FIXTURE says otherwise, and the fixture is what a domain file actually
# has to reproduce. Every assertion here goes through gate_try() against the control channel's
# sandbox and its request/result spool, so this section's dependencies are the control channel's,
# and it is homed with them. The map's row left the target to be decided at cut time by fixture
# affinity; this is that decision, recorded rather than assumed.
#
# AMBIENT BY DESIGN — AND THE REASON IS NOT THAT ARMING WOULD BREAK IT. This file inherits $C,
# $CTRL_LOG and $WALLET from the build_control_sandbox() call a control-family domain file makes
# ahead of it, and re-derives only its own spool path from $C. Calling the builder here would most
# likely be harmless — it creates rather than clears and never touches the control spool — but it
# would add a call that does not exist today, and it would buy nothing, because gate_try() is a
# function defined in another domain file and no arm written here can supply it. The cut that
# changes nothing about what executes is the one whose proof is strongest, so that is the one
# taken; the ambient inheritance is disclosed here instead, which is the shipped
# test-control-add-only-ssrf.sh precedent. $VALID_TARI is a top-level lib.sh constant.
#
# POSITION-LOCKED IN run.sh's SOURCE ORDER, not merely position-preferring. gate_try() and $UUID5
# are defined by test-control-add-only-ssrf.sh and deliberately outlive its source; run.sh sources
# that file immediately ahead of this one. That is the other half of the dependency its own header
# already discloses from its side. The carry-over guard below fails by name rather than silently,
# but it cannot make this file sourceable standalone — a missing gate_try() is loud (command not
# found, then the status assertions fail by name) and that is the honest state of it.
#
# WHAT THE INHERITANCE COSTS, stated so the next cut near here need not re-derive it: the gate_try()
# calls below write result files into the shared control spool, and a control-family file run.sh
# sources AHEAD of this one asserts that spool's exact result count. That assertion runs before this
# section writes anything, so it is untouched while this file stays where run.sh sources it.
#
# CONCURRENCY PROVENANCE, carried across the move because it is exactly what a move loses: this is
# the fork-heavy section — a per-key round-trip, each one a real preview->commit through the spool —
# that the fleet's notes name as the contention point when two suite runs share a box. A concurrent
# pair that reddens like cross-talk should be looked for here first.

: "${C:?}" "${CTRL_LOG:?}" "${WALLET:?}" "${VALID_TARI:?}" "${UUID5:?}"
RESULTS="$C/data/control/results"

echo "== black-box: editable-allowlist commit round-trip, every key (#522) =="
# Every key on CONTROL_DASHBOARD_EDITABLE_KEYS must actually round-trip a real preview->commit
# through the approval gate and land in config.json — not just pass a describe_change unit check.
# Fresh baseline with each tunable at a known value so every row below is a genuine single-key
# env diff (pool flips P2POOL_FLAGS + P2POOL_PORT, both allowlisted).
jq -n --arg w "$WALLET" '{
    monero:{mode:"local",wallet_address:$w,node_username:"u",node_password:"p",mem_limit:"4g",prep_blocks_threads:4,prune:false},
    tari:{wallet_address:"'"$VALID_TARI"'",mem_limit:"3g"}, p2pool:{pool:"main"},
    xvb:{enabled:true,donation_level:"donor"}, telegram:{daily_summary_time:"08:00"},
    dashboard:{secure:true,host:"box.lan",tari_required:true,check_for_updates:true,timezone:"UTC",
               hashrate_drop_threshold:50,hashrate_drop_minutes:10,
               auth:{username:"admin",password:"a control passphrase"},control:{enabled:true}}}' >"$C/config.json"
(cd "$C" && DOCKER_LOG="$CTRL_LOG" PATH="$C/bin:$PATH" ./pithead apply -y >/dev/null 2>&1)
COVERED=""        # env keys an actual round-trip exercised, accumulated by the two helpers below
roundtrip_key() { # <env-key(s), "/"-separated> <jq-set> <jq-read> <expected>
    COVERED="$COVERED $(printf '%s' "$1" | tr '/' ' ')"
    jq "$2" "$C/config.json" >"$C/cand.json"
    gate_try "$C/cand.json"
    assert_eq "$1 commit applies through the gate" "$(jq -r '.status' "$RESULTS/$UUID5.json" 2>/dev/null)" "applied"
    assert_eq "$1 landed in config.json" "$(jq -r "$3" "$C/config.json")" "$4"
}
roundtrip_key "XVB_ENABLED" '.xvb.enabled=false' '.xvb.enabled' "false"
roundtrip_key "XVB_DONATION_LEVEL" '.xvb.donation_level="whale"' '.xvb.donation_level' "whale"
roundtrip_key "TARI_REQUIRED" '.dashboard.tari_required=false' '.dashboard.tari_required' "false"
roundtrip_key "DASHBOARD_FAIL_CLOSED" '.dashboard.fail_closed=true' '.dashboard.fail_closed' "true"
roundtrip_key "DASHBOARD_CHECK_UPDATES" '.dashboard.check_for_updates=false' '.dashboard.check_for_updates' "false"
roundtrip_key "DASHBOARD_TZ" '.dashboard.timezone="Europe/Paris"' '.dashboard.timezone' "Europe/Paris"
roundtrip_key "MONERO_MEM_LIMIT" '.monero.mem_limit="5g"' '.monero.mem_limit' "5g"
roundtrip_key "TARI_MEM_LIMIT" '.tari.mem_limit="2g"' '.tari.mem_limit' "2g"
roundtrip_key "MONERO_PREP_THREADS" '.monero.prep_blocks_threads=8' '.monero.prep_blocks_threads' "8"
roundtrip_key "HASHRATE_DROP_THRESHOLD_PCT" '.dashboard.hashrate_drop_threshold=40' '.dashboard.hashrate_drop_threshold' "40"
roundtrip_key "HASHRATE_DROP_MINUTES" '.dashboard.hashrate_drop_minutes=15' '.dashboard.hashrate_drop_minutes' "15"
roundtrip_key "TELEGRAM_DAILY_SUMMARY_TIME" '.telegram.daily_summary_time="09:30"' '.telegram.daily_summary_time' "09:30"
roundtrip_key "P2POOL_FLAGS/P2POOL_PORT" '.p2pool.pool="mini"' '.p2pool.pool' "mini"
# The 25 allowlisted TELEGRAM_EVENT_* toggles (raffle_win added 2026-08: audit found it was the one
# event toggle missing from its siblings, all otherwise editable). wallet_changed + clearnet_exposed
# are deliberately NOT on the allowlist (tamper-evidence alarms; their refusal is asserted above),
# so they are excluded here. Each flips true->false as a single-key diff.
for ev in node_down node_recovered worker_offline worker_recovered worker_joined worker_left \
    sync_finished disk_space db_unhealthy db_reset xvb_no_share xvb_registration new_release \
    stack_online daily_summary hashrate_low hashrate_loss hugepages low_ram high_reject_rate \
    block_found payout_found payout_confirmed container_unhealthy raffle_win; do
    roundtrip_key "TELEGRAM_EVENT_$(printf '%s' "$ev" | tr 'a-z' 'A-Z')" \
        ".telegram.events.${ev}=false" ".telegram.events.${ev}" "false"
done

echo "== black-box: confirm-allowlist commit round-trip behind the typed APPLY (#1929) =="
# The tier above commits with no token. CONTROL_DASHBOARD_CONFIRM_KEYS is the OTHER committable
# tier, and until now nothing here proved a single one of its keys actually round-trips — only that
# a change needing a token is refused without one (test-confirm-approval.sh, one key). A key on an
# allowlist that no round-trip ever exercises is an allowlist entry nobody has seen work.
roundtrip_confirm() { # <env-key(s), "/"-separated> <jq-set> <jq-read> <expected>
    COVERED="$COVERED $(printf '%s' "$1" | tr '/' ' ')"
    jq "$2" "$C/config.json" >"$C/cand.json"
    # The token is load-bearing, not decoration: the SAME candidate must be refused without it, or
    # this row would pass just as happily for a key that had quietly fallen into the free tier.
    gate_try "$C/cand.json"
    assert_eq "$1 is refused with no typed APPLY" "$(jq -r '.status' "$RESULTS/$UUID5.json" 2>/dev/null)" "rejected"
    gate_try "$C/cand.json" APPLY
    assert_eq "$1 commit applies behind the typed APPLY" "$(jq -r '.status' "$RESULTS/$UUID5.json" 2>/dev/null)" "applied"
    assert_eq "$1 landed in config.json" "$(jq -r "$3" "$C/config.json")" "$4"
}
env_now() { run_sourced "$C" env_get_file "$C/.env" "$1"; }

# TARI_MODE, the #1929 subject: an operator turns merge-mining off and back on from the dashboard.
# Asserted on the RENDERED .env rather than config.json alone — config.json is what the gate wrote,
# the .env is what the containers are actually launched from, and only the second can show that the
# profile and the sync-gate flag followed the mode.
assert_eq "baseline renders the bundled Tari node" "$(env_now TARI_MODE)" "local"
tari_data_before="$(ls -A "$C/data/tari" 2>/dev/null | wc -l | tr -d ' ')"
roundtrip_confirm "TARI_MODE/COMPOSE_PROFILES" '.tari.mode="off"' '.tari.mode' "off"
assert_eq "off renders TARI_MODE=off" "$(env_now TARI_MODE)" "off"
assert_not_contains "off drops the local_tari profile" "$(env_now COMPOSE_PROFILES)" "local_tari"
assert_eq "off releases the sync gate — a machine that declined Tari still mines Monero" "$(env_now TARI_REQUIRED)" "false"
# The operator's own requirement: turning Tari off must not destroy the chain. Nothing in the
# commit path may touch the data dir — remove_deactivated_profile_containers removes the CONTAINER.
assert_eq "off leaves the Tari data dir untouched" "$(ls -A "$C/data/tari" 2>/dev/null | wc -l | tr -d ' ')" "$tari_data_before"
assert_eq "off leaves tari.data_dir pointing at the same chain" "$(jq -r '.tari.data_dir // "auto"' "$C/config.json")" "auto"
# ...and back on, the direction that proves this is a switch and not a one-way door.
roundtrip_confirm "TARI_MODE" '.tari.mode="local"' '.tari.mode' "local"
assert_eq "back on renders TARI_MODE=local" "$(env_now TARI_MODE)" "local"
assert_contains "back on restores the local_tari profile" "$(env_now COMPOSE_PROFILES)" "local_tari"

# The remaining confirm keys that need no live endpoint. TARI_CLEARNET_SYNC is asserted here as a
# ROUND TRIP; test-confirm-approval.sh asserts its refusal semantics on the Monero twin.
roundtrip_confirm "TARI_CLEARNET_SYNC" '.tari.clearnet_initial_sync=true' '.tari.clearnet_initial_sync' "true"
roundtrip_confirm "TARI_DATA_DIR" '.tari.data_dir="'"$C"'/data/tari2"' '.tari.data_dir' "$C/data/tari2"
roundtrip_confirm "MONERO_CLEARNET_SYNC" '.monero.clearnet_initial_sync=true' '.monero.clearnet_initial_sync' "true"
roundtrip_confirm "MONERO_OUT_PEERS" '.monero.out_peers=24' '.monero.out_peers' "24"
roundtrip_confirm "MONERO_DATA_DIR" '.monero.data_dir="'"$C"'/data/monero2"' '.monero.data_dir' "$C/data/monero2"
roundtrip_confirm "P2POOL_DATA_DIR" '.p2pool.data_dir="'"$C"'/data/p2pool2"' '.p2pool.data_dir' "$C/data/p2pool2"
roundtrip_confirm "DASHBOARD_DATA_DIR" '.dashboard.data_dir="'"$C"'/data/dashboard2"' '.dashboard.data_dir' "$C/data/dashboard2"
roundtrip_confirm "STRATUM_PORT" '.p2pool.stratum_port=3444' '.p2pool.stratum_port' "3444"
# PRUNE STARTS OFF IN THE BASELINE ABOVE, and that is not tidiness. monero_prune_flag defaults to
# TRUE (19-small-utilities.sh), so on a config with no monero.prune key the rendered MONERO_PRUNE is
# already 1 — setting it to true renders the SAME value, emits no porcelain row, and the commit then
# "applies" with no typed APPLY because there is nothing for the confirm gate to see. That is how
# this row read green while proving nothing; only the no-token half above caught it. ENABLE is also
# the only direction that is confirm-gated at all (describe_change flags DISABLE a host-only DEST),
# so a baseline that does not start pruned cannot exercise this key through the gate.
roundtrip_confirm "MONERO_PRUNE" '.monero.prune=true' '.monero.prune' "true"

echo "== black-box: every dashboard-committable key has a commit round-trip (#1929) =="
# TOTALITY, derived from the SHIPPED artifact rather than a hand list — a hand list is blind to the
# key nobody remembered, which is the whole failure mode here. $COVERED records what the helpers
# above actually RAN, not what this file says it covers, so deleting a row reds this too.
allow_set() { awk "/^$1='/{f=1} f{print} f && /'[[:space:]]*\$/{exit}" "$STACK" | tr -d "\n'" | sed "s/^$1=//;s/  */ /g;s/^ //"; }
# NAMED EXEMPTIONS with the reason each cannot run at tier 1. The four node-endpoint keys (#1888)
# are gated on preflight_remote_nodes, a REAL dial at the staged address: the sandbox has no node to
# answer it, so a round-trip here could only pass by defeating the probe that is the whole
# compensating control for that tier. They are tier-4 work (tests/integration, tests/os) by nature.
CONFIRM_TIER1_EXEMPT="MONERO_NODE_HOST MONERO_RPC_PORT MONERO_ZMQ_PORT TARI_GRPC_ADDRESS"
uncovered() { # <space-separated key list> -> the keys with no round-trip, minus the exemptions
    local k out=''
    for k in $1; do
        case " $COVERED $CONFIRM_TIER1_EXEMPT " in *" $k "*) ;; *) out="${out:+$out }$k" ;; esac
    done
    printf '%s' "$out"
}
# A FIRING CONTROL first: a comparison that can only ever print "" is not evidence of coverage. Seed
# a key that is on no allowlist and therefore in no round-trip, and prove uncovered() names it.
assert_eq "the totality check can report a missing round-trip" "$(uncovered "XVB_ENABLED NOT_A_REAL_KEY")" "NOT_A_REAL_KEY"
assert_eq "every CONTROL_DASHBOARD_EDITABLE_KEYS key round-trips" "$(uncovered "$(allow_set CONTROL_DASHBOARD_EDITABLE_KEYS)")" ""
assert_eq "every CONTROL_DASHBOARD_CONFIRM_KEYS key round-trips (or is exempt by name)" "$(uncovered "$(allow_set CONTROL_DASHBOARD_CONFIRM_KEYS)")" ""
# ...and the exemption list cannot quietly grow into a way to skip a key: every name on it must be a
# real confirm key, so an exemption for a key nobody gated reds rather than sitting there unread.
for k in $CONFIRM_TIER1_EXEMPT; do
    assert_contains "exempt key $k is a real confirm key" " $(allow_set CONTROL_DASHBOARD_CONFIRM_KEYS) " " $k "
done

echo "== black-box: the compose-profile token set is closed (#1929) =="
# WHY THIS GUARD EXISTS. COMPOSE_PROFILES is on the confirm allowlist so that a tari.mode switch
# commits with a typed APPLY instead of the Telegram tier — but that var is NOT tari's alone. What
# stops it widening monero's door is describe_change's DEST row on a local_node flip, and what stops
# a FUTURE profile inheriting the confirm tier for free is nothing at all. So pin the token set: add
# one and this reddens, forcing the allowlist comment in 42-control-policy-and-host-checks.sh to be
# re-read rather than inherited.
#
# Derived from the SHIPPED artifact, not retyped — a hand list cannot notice a token nobody
# remembered, which is the whole failure mode.
#
# `grep -a` is NOT decoration (#2086). The built pithead trips grep's binary heuristic on some
# filesystems — Docker Desktop's file sharing is one — and grep then prints "binary file matches"
# instead of the matches, so the extractor returns NOTHING and the equality row below compares ""
# to "" and passes. That is precisely what happened on the first Linux run of this file, and only
# the two COUNT rows caught it; the set-equality row was green by construction.
profile_tokens() { grep -a -oE 'profiles="(\$\{profiles:\+\$profiles,\})?[a-z_]+"' "$STACK" | sed 's/.*}//;s/profiles="//;s/"$//' | sort -u | tr '\n' ' ' | sed 's/ $//'; }
# FIRING CONTROL: an extractor that silently stopped matching prints "" and every comparison below
# would read as a clean, closed set. Prove it found something first.
_pt="$(profile_tokens)"
assert_eq "the profile-token extractor still matches render_env" "$(printf '%s' "$_pt" | wc -w | tr -d ' ')" "4"
assert_eq "COMPOSE_PROFILES carries exactly the four known tokens" "$_pt" "local_node local_tari payout_confirm tari_payout_confirm"
# ...and the container reaper knows every one of them. A profile whose container nothing removes is
# #795's defect returning: the profile goes inactive, compose does not count the container an orphan,
# and it keeps running against a config that says it should be gone.
reaped_tokens() { grep -a -oE '== \*,[a-z_]+,\*' "$STACK" | sed 's/.*,\([a-z_]*\),\*/\1/' | sort -u | tr '\n' ' ' | sed 's/ $//'; }
_rt="$(reaped_tokens)"
assert_eq "the reaper-token extractor still matches remove_deactivated_profile_containers" "$(printf '%s' "$_rt" | wc -w | tr -d ' ')" "4"
assert_eq "every renderable profile has a container the reaper removes (#795)" "$_rt" "$_pt"
