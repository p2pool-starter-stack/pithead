# shellcheck shell=bash
HARNESS_PID=""
HARNESS_START=""
HARNESS_DONE=0
HARNESS_PENDING=0
HARNESS_STATE=""

harness_prepare() {
    HARNESS_STATE="$E2E_DIR/results/e2e-harness.$1.state"
    on_bench "mkdir -p '$E2E_DIR/results' && printf 'intent\\n' > '$HARNESS_STATE.tmp' && mv '$HARNESS_STATE.tmp' '$HARNESS_STATE'" || return 1
    HARNESS_PENDING=1
}

drain_harness() {
    local state
    [ "$HARNESS_PENDING" = 1 ] && [ "$HARNESS_DONE" = 0 ] || return 0
    warn "detached harness is still active; terminating and draining it before restoration"
    HARNESS_PID=""
    for _ in {1..10}; do
        state="$(on_bench "cat '$HARNESS_STATE'" 2>/dev/null)" || state=""
        [[ "$state" =~ ^running\ ([0-9]+)\ ([0-9]+)$ ]] && HARNESS_PID="${BASH_REMATCH[1]}" && HARNESS_START="${BASH_REMATCH[2]}" && break
        sleep 1
    done
    [ -n "$HARNESS_PID" ] && [ -n "$HARNESS_START" ] || return 1
    until on_bench "sudo -n bash -c 'p=\$1 start=\$2; identity() { if ! test -r /proc/\$p/stat; then kill -0 -- -\$p 2>/dev/null && return 2 || return 1; fi; test \"\$(awk \"{print \\\$22}\" /proc/\$p/stat)\" = \"\$start\" || return 2; test \"\$(ps -o pgid= -p \$p | tr -d \" \")\" = \"\$p\" || return 2; tr \"\\0\" \"\\n\" </proc/\$p/cmdline | grep -Fxq \"./.e2e-run.sh\" || return 2; }; identity; rc=\$?; test \"\$rc\" -eq 1 && exit 0; test \"\$rc\" -eq 0 || exit 76; kill -TERM -- -\$p || exit 1; i=0; while test \"\$i\" -lt 30; do identity; rc=\$?; test \"\$rc\" -eq 1 && exit 0; test \"\$rc\" -eq 0 || exit 76; sleep 1; i=\$((i + 1)); done; identity || exit \$?; kill -KILL -- -\$p || exit 1' _ '$HARNESS_PID' '$HARNESS_START'"; do
        warn "could not prove the detached harness stopped; retaining ownership and retrying"
        sleep 5
    done
    HARNESS_DONE=1
}

drain_harness_or_refuse() {
    until drain_harness; do
        warn "harness launch state is uncertain; retaining ownership and retrying"
        sleep 5
    done
}

harness_finished() {
    local state rc
    state="$(on_bench "cat '$HARNESS_STATE'" 2>/dev/null)" || return 1
    [[ "$state" =~ ^running\ ([0-9]+)\ ([0-9]+)$ ]] || return 1
    HARNESS_PID="${BASH_REMATCH[1]}" HARNESS_START="${BASH_REMATCH[2]}"
    while :; do
        on_bench "sudo -n bash -c 'p=\$1 start=\$2; if ! test -r /proc/\$p/stat; then kill -0 -- -\$p 2>/dev/null && exit 76 || exit 0; fi; test \"\$(awk \"{print \\\$22}\" /proc/\$p/stat)\" = \"\$start\" || exit 76; exit 75' _ '$HARNESS_PID' '$HARNESS_START'"
        rc=$?
        case "$rc" in 0) break ;; 75) sleep 1 ;; *) return 1 ;; esac
    done
    HARNESS_DONE=1
}

# Safe pre-gate for the destructive phases: readiness (is this box fit to be a release server?)
# then the current-state battery. Both are read-only and cheap, and BOTH are binding — a run that
# warned and carried on graded the branch against a bench that was already broken, so a failure
# here refuses the destructive phases rather than reporting their fallout as a branch regression.
# A readiness refusal is the bench's, and is said to bench-ci as `readiness` (lib/e2e-env.sh) unless
# the phase already named Tari itself: a busy rig lock or a lost SSH refuses there too. A check
# refusal says nothing: that phase reads the deployed branch. The phase's stdout is teed to find
# that line; tee reads to EOF, so #2457's SIGPIPE cannot return, and the verdict is on_bench's own.
harness_pregate() { # <workers> <no_mining flags>
    local phase lock_pair said
    # Fed as a here-string rather than a pipe (#2457). The sub-phase does read both lines, so a pipe
    # carried the bytes correctly — but a pipeline whose reader can return before the write lands
    # leaves this writing into a closed pipe, and `set -o pipefail` then promotes that SIGPIPE to the
    # pipeline's status. A readiness that PASSED is read as "reported issues" and the destructive
    # launch is refused for a failure that never happened. A here-string has no pipeline to poison.
    # $( ) strips the trailing newline that <<< then re-adds, so `a` and `n` arrive byte-identical to
    # what the pipe delivered. The one difference: with NONCE unset the second read hits EOF (rc 1)
    # rather than reading an empty line. Nothing consumes that rc — the remote command joins its
    # reads with `;`, not `&&`, and sets no `-e` — so the values, and the phase's verdict, are unchanged.
    lock_pair="$(printf '%s\n%s' "${RIG_LOCK_PARENT_ACTOR:-}" "${RIG_LOCK_PARENT_NONCE:-}")"
    said="$(mktemp)" || return 1
    for phase in readiness check; do
        on_bench "IFS= read -r a; IFS= read -r n; cd '$E2E_DIR' && RIG_LOCK_PARENT_ACTOR=\"\$a\" RIG_LOCK_PARENT_NONCE=\"\$n\" RIG_LOCK_WAIT=$(quote_arg "${RIG_LOCK_WAIT:-0}") bash tests/integration/run.sh --local --dir '$E2E_DIR' --$phase --workers '$1' $2" <<<"$lock_pair" | tee "$said"
        [ "${PIPESTATUS[0]}" = 0 ] && continue
        warn "$phase reported issues (see above) — destructive phases refused"
        [ "$phase" = check ] || grep -Eq '^[[:space:]]*e2e-env: ' "$said" || e2e_env readiness
        rm -f "$said"
        return 1
    done
    rm -f "$said"
}

# Install the on-bench runner: it records `running <pid> <starttime>` BEFORE exec'ing the harness,
# which is what lets drain_harness/harness_finished prove the identity of the process they act on
# (a bare pid is not enough — pids get reused). `dir` owns the harness source, `target` is the
# stack it drives; --check points those at different checkouts.
harness_install_runner() {
    local runner
    runner="$(mktemp)" || return 1
    cat >"$runner" <<'RUNNER'
#!/usr/bin/env bash
set -uo pipefail
state="$1"; dir="$2"; target="$3"; workers="$4"; rearm_request="$5"; rearm_ack="$6"; rearm_id="$7"; shift 7
start=$(awk '{print $22}' "/proc/$$/stat") || exit 1
printf 'running %s %s\n' "$$" "$start" >"$state.tmp" && mv "$state.tmp" "$state"
mkdir -p "$dir/results"
IT_BORROW_REARM_REQUEST="$rearm_request" IT_BORROW_REARM_ACK="$rearm_ack" IT_BORROW_REARM_TOKEN="$rearm_id" \
    bash "$dir/tests/integration/run.sh" --local --dir "$target" --workers "$workers" "$@" \
    > "$dir/results/e2e-harness.log" 2>&1
echo $? > "$dir/results/e2e-harness.done"
RUNNER
    on_bench "cat > '$E2E_DIR/.e2e-run.sh' && chmod +x '$E2E_DIR/.e2e-run.sh'" <"$runner" || {
        rm -f "$runner"
        return 1
    }
    rm -f "$runner"
}
