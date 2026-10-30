# shellcheck shell=bash
on_bench() {
    local prefix=""
    if [ -n "${IT_SCRATCH_DIR:-}" ]; then
        prefix="export IT_SCRATCH_DIR=$(quote_arg "$IT_SCRATCH_DIR"); export TMPDIR=\"\$IT_SCRATCH_DIR\"; "
    fi
    parent_lock_on_bench "$BENCH_HOST" "$prefix$1"
}

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

# Called at wrapper preflight (all modes) and before inline pregates.
harness_clear_check_evidence() {
    on_bench "rm -rf $(quote_arg "$E2E_DIR/results/pregate-check")" || {
        warn "could not clear prior check evidence"
        return 1
    }
}

harness_pregate() {
    local phase pregate_records out_arg said errf stf st rc_on rc_err said_rc health_rc
    [[ "${IT_DASHBOARD_PASSWORD:-}" != *$'\n'* ]] || {
        warn "The dashboard credential contains a newline."
        return 1
    }
    printf -v pregate_records '%s\n%s\n%s' "${RIG_LOCK_PARENT_ACTOR:-}" "${RIG_LOCK_PARENT_NONCE:-}" "${IT_DASHBOARD_PASSWORD:-}"
    said="" errf="" stf=""
    said="$(mktemp)" && errf="$(mktemp)" && stf="$(mktemp)" || {
        rm -f "$said" "$errf" "$stf"
        return 1
    }
    # Keep the asserted check invocation outside the destructive harness's results cleanup.
    # Clear it before readiness too: a refused job must not collect an earlier job's check.
    harness_clear_check_evidence || {
        rm -f "$said" "$errf" "$stf"
        return 1
    }
    for phase in readiness check; do
        out_arg=""
        [ "$phase" != check ] || out_arg="--out $(quote_arg "$E2E_DIR/results/pregate-check")"
        (
            on_bench "IFS= read -r a || exit 1; IFS= read -r n || exit 1; IFS= read -r dp || exit 1; cd '$E2E_DIR' && IT_DASHBOARD_PASSWORD=\"\$dp\" RIG_LOCK_PARENT_ACTOR=\"\$a\" RIG_LOCK_PARENT_NONCE=\"\$n\" RIG_LOCK_WAIT=$(quote_arg "${RIG_LOCK_WAIT:-0}") bash tests/integration/run.sh --local --dir '$E2E_DIR' --$phase --workers '$1' $out_arg $2" <<<"$pregate_records" 2>&1 1>&3 3>&- | tee "$errf" >&2 3>&-
            printf '%s %s\n' "${PIPESTATUS[0]}" "${PIPESTATUS[1]}" >"$stf"
        ) 3>&1 | tee "$said"
        st=("${PIPESTATUS[@]}")
        rc_on="" rc_err=""
        if [ "${st[0]}" != 0 ] || [ "${st[1]}" != 0 ] || ! read -r rc_on rc_err <"$stf" ||
            [ "$rc_err" != 0 ] || ! [[ "$rc_on" =~ ^[0-9]+$ ]]; then
            warn "could not record the $phase phase's output — destructive phases refused"
            rm -f "$said" "$errf" "$stf"
            return 1
        fi
        [ "$rc_on" = 0 ] && continue
        warn "$phase reported issues (see above) — destructive phases refused"
        if [ "$phase" = readiness ]; then
            # A stack that is not healthy after the deploy is the branch's to explain, not the bench's.
            grep -aEq '^[[:space:]]*e2e-env: ' "$said"
            said_rc=$?
            grep -aEq '(✗|- readiness:).*stack is healthy \(pithead status\)' "$said" "$errf"
            health_rc=$?
            if [ "$said_rc" -gt 1 ] || [ "$health_rc" -gt 1 ]; then
                warn "could not read the readiness phase's recorded output"
            elif [ "$said_rc" = 1 ] && [ "$health_rc" = 1 ]; then
                e2e_env readiness
            fi
        fi
        rm -f "$said" "$errf" "$stf"
        return 1
    done
    rm -f "$said" "$errf" "$stf"
}

harness_launch_records() {
    local rollback_b64 pools_b64 record
    rollback_b64="$(printf '%s' "${IT_RIG_ROLLBACK_CHANGES:-}" | base64 | tr -d '\n')" || die "Failed to encode IT_RIG_ROLLBACK_CHANGES."
    pools_b64="$(printf '%s' "${IT_RIG_POOLS_PROBE:-}" | base64 | tr -d '\n')" || die "Failed to encode IT_RIG_POOLS_PROBE."
    HARNESS_RECORDS=""
    for record in "${IT_RIG_TOKEN:-}" "${RIG_LOCK_PARENT_ACTOR:-}" "${RIG_LOCK_PARENT_NONCE:-}" "$rollback_b64" "$pools_b64" \
        "${IT_MONERO_VIEW_KEY:-}" "${IT_TARI_VIEW_KEY:-}" "${IT_TARI_SPEND_PUBLIC_KEY:-}" "${ROTATE_FIXTURE_ATTESTATION:-}" "${IT_DASHBOARD_PASSWORD:-}"; do
        [[ "$record" != *$'\n'* ]] || die "A harness launch record contains a newline."
        HARNESS_RECORDS+="$record"$'\n'
    done
    local name supplied=""
    for name in IT_MONERO_VIEW_KEY IT_TARI_VIEW_KEY IT_TARI_SPEND_PUBLIC_KEY; do
        supplied+=" $name=$([ -n "${!name:-}" ] && echo set || echo unset)"
    done
    step "payout-confirm keys forwarded to the harness:$supplied"
}

# Install the on-bench runner: it records `running <pid> <starttime>` BEFORE exec'ing the harness,
# which is what lets drain_harness/harness_finished prove the identity of the process they act on
# (a bare pid is not enough — pids get reused). `dir` owns the harness source, `target` is the
# stack it drives; --check points those at different checkouts.
harness_install_runner() {
    local runner
    runner="$(mktemp)" || return 1
    # Pin the runner-owned target scratch even when SSH drops ambient variables.
    printf '#!/usr/bin/env bash\n' >"$runner"
    printf 'export CI_RIG_RECOVERY_HOLD=%s\n' "$(quote_arg "${CI_RIG_RECOVERY_HOLD:-0}")" >>"$runner"
    if [ -n "${IT_SCRATCH_DIR:-}" ]; then
        printf 'export IT_SCRATCH_DIR=%s\n' "$(quote_arg "$IT_SCRATCH_DIR")" >>"$runner"
    fi
    cat >>"$runner" <<'RUNNER'
set -uo pipefail
state="$1"; dir="$2"; target="$3"; workers="$4"; rearm_request="$5"; rearm_ack="$6"; rearm_id="$7"; shift 7
start=$(awk '{print $22}' "/proc/$$/stat") || exit 1
printf 'running %s %s\n' "$$" "$start" >"$state.tmp" && mv "$state.tmp" "$state"
mkdir -p "$dir/results"
if [ -n "${IT_SCRATCH_DIR:-}" ]; then
    export TMPDIR="$IT_SCRATCH_DIR"
    if ! { [ -d "$TMPDIR" ] && [ ! -L "$TMPDIR" ] &&
        scratch_device=$(stat -c %d "$TMPDIR") && parent_device=$(stat -c %d "$TMPDIR/..") &&
        [ -n "$scratch_device" ] && [ "$scratch_device" = "$parent_device" ] &&
        probe=$(mktemp "$TMPDIR/harness-scratch.XXXXXX") && rm -f "$probe"; }; then
        echo 'e2e: target scratch unavailable or on another filesystem' >"$dir/results/e2e-harness.log"
        echo 1 >"$dir/results/e2e-harness.done"
        exit 1
    fi
fi
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
