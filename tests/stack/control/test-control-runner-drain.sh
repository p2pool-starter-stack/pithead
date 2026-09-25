# shellcheck shell=bash
: "${STACK_SUITE:?is unset: this file is a tests/stack/run.sh fragment, not a script — run tests/stack/run.sh}"
# Control-runner drain domain (#2363): a re-provision stops the trigger, waits (bounded) for a
# request the runner already claimed, and only then rewrites or removes the units; the runner
# itself takes no mutation lock. Moved out of test-control-provisioning.sh unchanged; it runs
# straight after it in tests/stack/run.sh, so execution order is the same.
# Standalone-sourceable: every fixture ($PCD, $PCL) is built here under $SANDBOX, and nothing
# else in the suite reads them. $SANDBOX and $STACK come from lib.sh.

: "${SANDBOX:?}" "${STACK:?}"

echo "== unit: provision_control_runner drains an in-flight claim before touching the runner (#2363) =="
# A `.claim.<pid>` exists only while the runner works a request. Stop the trigger, wait for the
# claim, then touch the units.
PCD="$SANDBOX/pcd"
mkdir -p "$PCD/units" "$PCD/bin" "$PCD/mine/data/control/requests"
printf '#!/usr/bin/env bash\n[ "$1" = "-s" ] && { echo Linux; exit 0; }\nexec uname "$@"\n' >"$PCD/bin/uname"
printf '#!/usr/bin/env bash\nexit 0\n' >"$PCD/bin/systemctl"
chmod +x "$PCD/bin/uname" "$PCD/bin/systemctl"

pcd_run() { # <claim: yes|no> <clears-on-first-wait: yes|no> [enabled=false] [own-claim=false] — seed own units (+claim), converge them
    rm -f "$PCD/mine/data/control/.claim.1" "$PCD/calls"
    printf '[Service]\nExecStart=%s/pithead control-run-pending\n' "$PCD/mine" >"$PCD/units/pithead-control.service"
    printf '[Path]\nPathExistsGlob=%s/data/control/requests/*.json\n' "$PCD/mine" >"$PCD/units/pithead-control.path"
    [ "$1" = yes ] && : >"$PCD/mine/data/control/.claim.1"
    (
        cd "$PCD/mine" || exit
        PATH="$PCD/bin:$PATH"
        # shellcheck disable=SC1090
        source "$STACK"
        set +e
        log() { :; }
        sudo() { echo "sudo:$*" >>"$PCD/calls"; } # side file: the function redirects sudo output
        # No real 30s wait: `sleep` clears the claim on its first call (the re-check ends the wait)
        # or never does (the bound fires and the apply still proceeds).
        if [ "$2" = yes ]; then
            sleep() { rm -f "$PCD/mine/data/control/.claim.1"; }
        else
            sleep() { :; }
        fi
        unset PITHEAD_LOCK_HELD
        [ "${4:-false}" = true ] && export PITHEAD_CONTROL_RUNNER_PID=1 || unset PITHEAD_CONTROL_RUNNER_PID
        PITHEAD_ENGINE=podman PITHEAD_UNIT_DIR="$PCD/units" DASHBOARD_CONTROL_ENABLED="${3:-false}" \
            CONTROL_DIR="$PCD/mine/data/control" provision_control_runner 2>&1
        cat "$PCD/calls" 2>/dev/null
    )
}

out="$(pcd_run no -)"
assert_contains "no claim in flight -> stops the trigger, then still removes the units" "$out" "sudo:systemctl stop pithead-control.path"
[[ "$out" == *"systemctl stop pithead-control.path"*"rm -f"* ]] && order=stop-then-rm || order=other
assert_eq "no claim in flight -> stop happens BEFORE the units are taken away" "$order" "stop-then-rm"
assert_not_contains "no claim in flight -> no timeout warning" "$out" "Timed out"

out="$(pcd_run yes yes)"
assert_not_contains "a claim that clears on the first poll -> no timeout warning" "$out" "Timed out"
assert_contains "a claim that clears on the first poll -> the drain still ends in the units being removed" "$out" "sudo:rm -f"

out="$(pcd_run yes no)"
assert_contains "a claim that never clears -> bounded wait times out with a clear message" "$out" "Timed out after 30s"
[[ "$out" == *"Timed out after 30s"*"sudo:rm -f"* ]] && order=timeout-then-proceed || order=other
assert_eq "a claim that never clears -> the apply still proceeds after the bound, not stuck forever" "$order" "timeout-then-proceed"

out="$(pcd_run yes yes true)"
[[ "$out" == *"systemctl stop pithead-control.path"*"tee $PCD/units/pithead-control.service"*"systemctl enable --now pithead-control.path"* ]] && order=drain-rewrite-enable || order=other
assert_eq "enabled re-provision drains before rewriting and re-enabling the runner" "$order" "drain-rewrite-enable"

out="$(pcd_run yes no true true)"
assert_not_contains "a child apply does not spend 30 seconds waiting on its parent runner's claim" "$out" "Timed out"
assert_contains "ignoring the parent claim still converges the enabled runner" "$out" "systemctl enable --now pithead-control.path"
unset PCD out order
unset -f pcd_run

echo "== unit: the runner takes no mutation lock; only a re-provision does (#2363) =="
# A lock-free verb (preview, diag-*, os-*, worker-*) neither waits behind a shell verb's window nor
# holds one against it. Fake handler, real lock, real runner loop.
PCL="$SANDBOX/pcl"
mkdir -p "$PCL/requests"
pcl_runner() { # <lock-timeout> <handler-seconds> — drain one diag-doctor request; echo its output
    printf '{"id":"%s","action":"diag-doctor"}\n' "11111111-1111-4111-8111-111111111111" >"$PCL/requests/r.json"
    (
        # shellcheck disable=SC1090
        source "$STACK"
        set +e
        unset PITHEAD_LOCK_HELD
        env_get() { [ "$1" = DASHBOARD_CONTROL_ENABLED ] && printf true || printf '%s' "$PCL"; }
        render_masked_config() { :; }
        control_redact_stale_kits() { :; }
        control_diag_doctor() { : >"$PCL/started" && sleep "$PCL_HOLD"; }
        PCL_HOLD="$2" PITHEAD_LOCK_FILE="$PCL/lock" PITHEAD_LOCK_TIMEOUT="$1" control_run_pending 2>&1
    )
}
# (a) A shell verb holds the window; a lock-free verb queued now starts at once.
rm -f "$PCL/started"
(
    exec 9>>"$PCL/lock"
    flock 9
    exec sleep 30
) &
PCL_HOLDER=$!
pcl_held() { ! flock -n "$PCL/lock" true 2>/dev/null; }
wait_while_alive "$PCL_HOLDER" pcl_held
out=$(pcl_runner 5 0)
assert_not_contains "a lock-free verb queued while a shell verb holds the lock does not wait for it" "$out" "waiting up to"
assert_eq "and it runs" "$([ -f "$PCL/started" ] && echo started)" "started"
kill "$PCL_HOLDER" 2>/dev/null || true
wait "$PCL_HOLDER" 2>/dev/null || true
# (b) The runner is inside a lock-free verb; a shell apply takes the window at once.
rm -f "$PCL/started"
pcl_runner 30 3 >/dev/null &
PCL_RUNNER=$!
pcl_started() { [ -f "$PCL/started" ]; }
wait_while_alive "$PCL_RUNNER" pcl_started
rc=0
(
    # shellcheck disable=SC1090
    source "$STACK"
    unset PITHEAD_LOCK_HELD PITHEAD_CONTROL_RUNNER_PID
    warn() { :; }
    PITHEAD_LOCK_FILE="$PCL/lock" PITHEAD_LOCK_TIMEOUT=1 mutation_lock_acquire apply
) || rc=$?
assert_eq "a shell apply during a lock-free runner verb acquires the window at once" "$rc" "0"
wait "$PCL_RUNNER" 2>/dev/null || true
unset PCL PCL_HOLDER PCL_RUNNER rc out
unset -f pcl_runner pcl_held pcl_started
