# shellcheck shell=bash
: "${STACK_SUITE:?is unset: this file is a tests/stack/run.sh fragment, not a script — run tests/stack/run.sh}"
# The post-commit release of the held chain services retries, keeps its order, and alerts (#1684).
# A data_migration update boots with the chain services held; once the slot commits, pithead-boot
# releases them with `./pithead up`. On the bench that `up` landed while p2pool — started by the
# held `up` — was mid-stop, compose aborted the WHOLE start on podman's "container state improper",
# and the swallowed failure left every held service down under a dashboard reading `updated`;
# nothing retried short of a reboot a committed appliance has no reason to take. The release is now
# `release_held_chain_services`, above pithead-boot's sourcing boundary and driven here with a
# stubbed `pithead` that fails a scripted number of times: the `up` is retried a bounded number of
# times, the markers go BEFORE the first try, the release line (the tier-4 battery's commit
# boundary) prints BEFORE the first `up`, and the last failure is one named FAULT line on stderr,
# never a failed boot. The call site is below the boundary and asserted by the script's text.
# Sourced by tests/stack/run.sh.

echo "== unit: release_held_chain_services — the post-commit up is retried, ordered, and alerted (#1684) =="
RL="$SANDBOX/boot-release"
rm -rf "$RL"
mkdir -p "$RL"
# The stub fails its first N calls and succeeds after. Every call appends to the order file, which
# also takes the function's stdout, so the file reads as the sequence of events.
rl_stub() { # <fails-before-success>
    cat >"$RL/pithead" <<EOF
#!/usr/bin/env bash
echo "up:\$*" >>"$RL/order"
n=\$(cat "$RL/calls" 2>/dev/null || echo 0); n=\$((n + 1)); echo "\$n" >"$RL/calls"
[ "\$n" -gt $1 ]
EOF
    chmod +x "$RL/pithead"
}
rl_run() { # <fails-before-success> <tries> -> "rc=N"; stdout lands in order, stderr in err
    rl_stub "$1"
    rm -f "$RL/calls" "$RL/order" "$RL/err"
    touch "$RL/.os-migration-pending" "$RL/.os-data-floor.prev"
    (
        cd "$RL" || exit 1
        export PITHEAD_RELEASE_UP_TRIES="$2" PITHEAD_RELEASE_UP_PAUSE=0
        # shellcheck disable=SC1090
        source "$ROOT/os/overlay/pithead-boot" 2>/dev/null
        release_held_chain_services >>"$RL/order" 2>"$RL/err"
        echo "rc=$?"
    )
}

# Positive control first: a first-try success is one up, no retry line, no fault, markers gone.
rl_out=$(rl_run 0 5)
assert_eq "an up that succeeds first time releases with rc 0" "$rl_out" "rc=0"
assert_eq "and calls up exactly once" "$(cat "$RL/calls")" "1"
assert_not_contains "no retry is announced when none happened" "$(cat "$RL/order")" "retrying"
assert_eq "no fault is alerted" "$(wc -c <"$RL/err" | tr -d ' ')" "0"
assert_eq "the migration marker is consumed by the release" \
    "$([ -f "$RL/.os-migration-pending" ] && echo present || echo gone)" "gone"
assert_eq "and the floor record with it (the commit-side removal, #1393)" \
    "$([ -f "$RL/.os-data-floor.prev" ] && echo present || echo gone)" "gone"
# The order the tier-4 battery keys on: the release line marks the commit boundary in the journal
# and must land BEFORE the first up, whose start can take minutes.
assert_eq "the release line prints BEFORE the first up" "$(head -n1 "$RL/order")" \
    "pithead-boot: slot committed — chain services released, the data migration runs now"
assert_eq "and the up follows it" "$(sed -n '2p' "$RL/order")" "up:up"

# #1684 itself: two transitional failures, then the stack comes up. Mutation run: drop the loop
# (one bare up) -> the rc row goes red; drop the announcement -> the count row goes red.
rl_out=$(rl_run 2 5)
assert_eq "an up that fails twice on a transitional container still releases (rc 0)" "$rl_out" "rc=0"
assert_eq "it took exactly three ups — the two failures and the success" "$(cat "$RL/calls")" "3"
assert_eq "each failure short of the last try is announced" "$(grep -c 'retrying in' "$RL/order")" "2"
assert_contains "and the announcement counts the try" "$(cat "$RL/order")" "(try 2 of 5)"
assert_eq "no fault is alerted for a release that succeeded" "$(wc -c <"$RL/err" | tr -d ' ')" "0"

# Bounded: every try fails. The markers still went first (the next boot takes the normal path),
# the fault is alerted ONCE on stderr naming the recovery, and the function returns 1 — the caller's
# `|| true` is what keeps the boot from failing, asserted by text below.
rl_out=$(rl_run 99 3)
assert_eq "a stack that never comes up returns 1 after the last try" "$rl_out" "rc=1"
assert_eq "and it tried exactly PITHEAD_RELEASE_UP_TRIES times" "$(cat "$RL/calls")" "3"
assert_eq "the last failure is not followed by a retry announcement" "$(grep -c 'retrying in' "$RL/order")" "2"
assert_eq "the fault is alerted exactly once" "$(grep -c 'FAULT' "$RL/err")" "1"
assert_contains "the alert says the migration has NOT run" "$(cat "$RL/err")" "the data migration has NOT run"
assert_contains "and names the recovery" "$(cat "$RL/err")" "run './pithead up' from /data/pithead"
assert_eq "the marker was still consumed — re-holding would gate on a commit that already happened" \
    "$([ -f "$RL/.os-migration-pending" ] && echo present || echo gone)" "gone"

# The shipped defaults: five tries ten seconds apart. The bench's transition lasted under a second;
# forty seconds of patience is nothing against a boot unit that runs with TimeoutStartSec=infinity.
rl_defaults=$(
    cd "$RL" || exit 1
    # shellcheck disable=SC1090
    source "$ROOT/os/overlay/pithead-boot" 2>/dev/null
    echo "$RELEASE_UP_TRIES/$RELEASE_UP_PAUSE"
)
assert_eq "the shipped defaults are five tries, ten seconds apart" "$rl_defaults" "5/10"

# The call site sits below the sourcing boundary, so its wiring is asserted by the script's text:
# the hold-chain commit block calls the function and tolerates its failure, and no bare, un-retried
# `./pithead up || true` — the original defect — is back on the release path.
BOOTSCRIPT="$ROOT/os/overlay/pithead-boot"
assert_eq "the hold-chain commit block calls release_held_chain_services and tolerates its failure" \
    "$(grep -cE '^\s*\[ "\$hold_chain" = 1 \] && \{ release_held_chain_services \|\| true; \}' "$BOOTSCRIPT" || true)" "1"
assert_eq "no bare, un-retried up remains on the release path" \
    "$(grep -cE '^\s*\./pithead up \|\| true' "$BOOTSCRIPT" || true)" "0"
assert_eq "pithead-boot gates its three up calls" \
    "$(grep -cE '^\s*PITHEAD_BOOT_GATE=1 ([A-Z_]+=[^ ]+ )*\./pithead up\b' "$BOOTSCRIPT" || true)" "3"
assert_eq "every boot up leaves the miner to the post-commit leg" \
    "$(grep -E '^\s*([A-Z_]+=[^ ]+ )*\./pithead up\b' "$BOOTSCRIPT" | grep -vc 'PITHEAD_BOOT_GATE=1 ' || true)" "0"
unset -f rl_stub rl_run
unset RL rl_out rl_defaults BOOTSCRIPT

echo "== unit: up starts the enabled built-in miner outside the boot gate (#3375) =="
mk_tmpdir UPM
mkdir -p "$UPM/rigforge" "$UPM/bin"
printf '#!/usr/bin/env bash\necho "rigforge:$1 appliance=${RIGFORGE_APPLIANCE:-unset}" >>"$RF_LOG"\nexit "${RF_RC:-0}"\n' >"$UPM/rigforge/rigforge.sh"
printf '#!/usr/bin/env bash\necho "systemctl:$*" >>"$RF_LOG"\n' >"$UPM/bin/systemctl"
chmod +x "$UPM/rigforge/rigforge.sh" "$UPM/bin/systemctl"
printf '{"local_miner":{"enabled":true}}' >"$UPM/config.json"
printf 'STRATUM_PORT=3333\n' >"$UPM/.env"
upm_up() {
    local stub
    for stub in mutation_lock_acquire mutation_lock_release require_deployed validate_config_document \
        warn_missing_data_dirs migrate_compose_project apply_tor_egress_firewall provision_egress_check_units \
        provision_lan_guard_check_units verify_release_images reconcile_compose_images print_clearnet_banner \
        announce_dashboard_url print_first_run_epilogue; do
        eval "$stub() { :; }"
    done
    compose_up_checked() { echo "compose:up $*" >>"$RF_LOG"; }
    main up
}
upm_run() {
    (
        export PITHEAD_APPLIANCE=1 PITHEAD_RIGFORGE_DIR="$UPM/rigforge" RF_LOG="$UPM/calls" PATH="$UPM/bin:$PATH"
        for assignment; do export "${assignment?}"; done
        run_sourced "$UPM" upm_up >/dev/null 2>&1
    )
}
: >"$UPM/calls"
upm_run
assert_rc "up -> rc 0" "$?" "0"
assert_eq "up starts the enabled miner after the stack, so a restore-then-up mines again" \
    "$(tr '\n' ' ' <"$UPM/calls")" "compose:up -d rigforge:setup appliance=1 "
: >"$UPM/calls"
upm_run PITHEAD_BOOT_GATE=1
assert_rc "boot-gate up -> rc 0" "$?" "0"
assert_eq "boot-gate up leaves the miner to the post-commit leg" "$(cat "$UPM/calls")" "compose:up -d"
: >"$UPM/calls"
upm_run RF_RC=1
assert_rc "a failed miner setup does not fail up" "$?" "0"
assert_contains "the failed setup did run" "$(cat "$UPM/calls")" "rigforge:setup"
unset -f upm_up upm_run
rm -rf "$UPM"
unset UPM
