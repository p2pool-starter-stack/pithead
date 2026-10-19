# shellcheck shell=bash
INLINE_PREGATE_PID="" INLINE_PREGATE_REMOTE_BASE="" INLINE_PREGATE_STARTING=0
E2E_EXIT_OWNER=$BASHPID
rig_lock_remote_release() {
    [ -n "${RIG_LOCK_SSH_PID:-}" ] || return 0
    local rc=0
    # EOF alone can be held open by descendants inheriting FD 8. End our own remote
    # shell explicitly; never remove a holder or signal a process on the loaner.
    (printf 'exit\n' >&8) 2>/dev/null || rc=1
    exec 8>&-
    wait "$RIG_LOCK_SSH_PID" || rc=1
    RIG_LOCK_SSH_PID=""
    return "$rc"
}

inline_pregate_alive() {
    local processes
    processes="$(ps -axo pgid=,stat=)" || return 2
    awk -v group="$INLINE_PREGATE_PID" '$1 == group && $2 !~ /^Z/ { alive=1 } END { exit !alive }' <<<"$processes"
}

drain_local_pregate() {
    if [ "$INLINE_PREGATE_STARTING" = 1 ] && [ "${!:-}" != "$INLINE_PREGATE_PREVIOUS_JOB" ]; then
        INLINE_PREGATE_PID=$!
    fi
    [ -n "${INLINE_PREGATE_PID:-}" ] || return 0
    local deadline state sig
    for sig in TERM KILL; do
        kill -"$sig" -- "-$INLINE_PREGATE_PID" 2>/dev/null || true
        sudo -n kill -"$sig" -- "-$INLINE_PREGATE_PID" 2>/dev/null || true
        deadline=$((SECONDS + 5))
        while :; do
            inline_pregate_alive
            state=$?
            if [ "$state" -eq 1 ]; then
                wait "$INLINE_PREGATE_PID" 2>/dev/null || true
                INLINE_PREGATE_PID=""
                return 0
            fi
            [ "$state" -eq 0 ] || return 1
            [ "$SECONDS" -lt "$deadline" ] || break
            sleep .1
        done
    done
    return 1
}

drain_inline_pregate() {
    drain_local_pregate || return 1
    if [ -n "${INLINE_PREGATE_REMOTE_BASE:-}" ]; then
        local phase
        for phase in readiness check; do
            on_bench "bash $(quote_arg "$E2E_DIR/tests/integration/lib/inline-pregate-remote.sh") drain $(quote_arg "$INLINE_PREGATE_REMOTE_BASE.$phase")" || return 1
        done
        INLINE_PREGATE_REMOTE_BASE=""
    fi
}

run_inline_pregate() {
    local rc=0 monitor=0
    [[ "$-" != *m* ]] || monitor=1
    INLINE_PREGATE_REMOTE_BASE=""
    if [ -z "${RIG_LOCK_PARENT_ACTOR:-}${RIG_LOCK_PARENT_NONCE:-}${RIG_LOCK_PARENT_FD:-}" ]; then
        INLINE_PREGATE_REMOTE_BASE="$E2E_DIR/results/inline-pregate.$$.$RANDOM"
        on_bench "mkdir -p $(quote_arg "$E2E_DIR/results") && umask 077 && printf 'intent\n' >$(quote_arg "$INLINE_PREGATE_REMOTE_BASE.readiness") && printf 'intent\n' >$(quote_arg "$INLINE_PREGATE_REMOTE_BASE.check")" || return 1
    fi
    INLINE_PREGATE_PREVIOUS_JOB=${!:-}
    INLINE_PREGATE_STARTING=1
    set -m
    (
        trap - EXIT
        set +m
        local out_fd err_fd out_pid err_pid status=0
        exec {out_fd}> >(redact_remote_output)
        out_pid=$!
        exec {err_fd}> >(redact_remote_output >&2)
        err_pid=$!
        harness_pregate "$@" 1>&"$out_fd" 2>&"$err_fd" || status=$?
        exec {out_fd}>&- {err_fd}>&-
        wait "$out_pid" || status=1
        wait "$err_pid" || status=1
        exit "$status"
    ) &
    INLINE_PREGATE_PID=$!
    INLINE_PREGATE_STARTING=0
    [ "$monitor" -eq 1 ] || set +m
    wait "$INLINE_PREGATE_PID" || rc=$?
    drain_inline_pregate || return 1
    return "$rc"
}

e2e_exit() {
    local rc=$? restore_rc=0
    [ "$BASHPID" = "$E2E_EXIT_OWNER" ] || exit "$rc"
    drain_inline_pregate || {
        warn "inline pregate could not be stopped; refusing baseline restoration"
        exit 1
    }
    # A restore refusal calls exit. Isolate it so every outcome still reaps our child.
    (restore_all "$rc") || restore_rc=$?
    rig_lock_remote_release || restore_rc=1
    [ "$restore_rc" -eq 0 ] || rc=$restore_rc
    exit "$rc"
}

rig_lock_parent_claim_verify() {
    local actor="${RIG_LOCK_PARENT_ACTOR:-}" nonce="${RIG_LOCK_PARENT_NONCE:-}"
    local lf="${RIG_LOCK_FILE:-/var/lock/rig-e2e.lock}" hf="${RIG_LOCK_HOLDER:-/run/rig-e2e.holder}" got_actor got_nonce _ rc
    [[ "$actor" =~ ^[A-Za-z0-9._:-]+$ && "$nonce" =~ ^[0-9a-f]{32}$ ]] || return 1
    [ -f "$lf" ] && [ ! -L "$lf" ] && [ -f "$hf" ] && [ ! -L "$hf" ] || return 1
    IFS=' ' read -r got_actor got_nonce _ <"$hf" || return 1
    [ "$got_actor" = "$actor" ] && [ "$got_nonce" = "nonce=$nonce" ] || return 1
    flock -E 75 -n -x "$lf" true
    rc=$?
    [ "$rc" -eq 75 ]
}

rig_lock_parent_verify() {
    local fd="${RIG_LOCK_PARENT_FD:-}" actor="${RIG_LOCK_PARENT_ACTOR:-}" nonce="${RIG_LOCK_PARENT_NONCE:-}"
    local proof="${RIG_LOCK_PARENT_PROOF:-/run/rig-e2e.proof}" challenge
    [[ "$fd" =~ ^[3-9][0-9]*$ ]] && [ -p "/dev/fd/$fd" ] && [ -w "/dev/fd/$fd" ] || return 1
    [ -f "$proof" ] && [ ! -L "$proof" ] || return 1
    rig_lock_parent_claim_verify || return 1
    challenge="$actor:$nonce:$$:$RANDOM"
    printf '%s\n' "$challenge" >&"$fd" || return 1
    for _ in {1..20}; do
        [ "$(cat "$proof" 2>/dev/null)" = "$challenge" ] && rig_lock_parent_claim_verify && return
        sleep .1
    done
    return 1
}

parent_lock_on_bench() { # <host> <command>; inherited lock descriptors cannot cross SSH
    local host="$1"
    shift
    if [ -n "${RIG_LOCK_PARENT_ACTOR:-}${RIG_LOCK_PARENT_NONCE:-}${RIG_LOCK_PARENT_FD:-}" ]; then
        case "$host" in
        localhost | 127.0.0.1 | "$(hostname)" | "$(hostname -s)" | "$(hostname -f)") bash -c "$1" ;;
        *)
            printf 'parent-held lock descriptor cannot cross SSH to %s\n' "$host" >&2
            return 1
            ;;
        esac
    else
        ssh "${SSH_OPTS[@]}" "$host" "$1"
    fi
}

rig_lock_parent_use() {
    [ "$IT_MODE" = local ] || {
        it_err "parent-lock continuity is valid only for a local nested runner"
        return 1
    }
    rig_lock_parent_verify || return 1
    _RIG_LOCK_PARENT_VERIFIED=1
    it_log "Verified parent-held rig lock (${RIG_LOCK_PARENT_ACTOR})."
}

parent_lock_checkpoint() { # <phase> [host]; e2e-side remote verification
    local phase="$1" host="${2:-$BENCH_HOST}" miner_fd="${RIG_LOCK_PARENT_MINER_FD:-}" challenge
    [ -n "${RIG_LOCK_PARENT_ACTOR:-}" ] || [ -n "${RIG_LOCK_PARENT_NONCE:-}" ] || return 0
    case "$host" in
    localhost | 127.0.0.1 | "$(hostname)" | "$(hostname -s)" | "$(hostname -f)")
        rig_lock_parent_verify || return 1
        step "parent-held lock verified on $host before $phase"
        return
        ;;
    esac
    [[ "$miner_fd" =~ ^[3-9][0-9]*$ ]] && [ -w "/dev/fd/$miner_fd" ] || return 1
    challenge="${RIG_LOCK_PARENT_ACTOR}:${RIG_LOCK_PARENT_NONCE}:$$:$RANDOM"
    printf '%s\n' "$challenge" >&"$miner_fd" || return 1
    # shellcheck disable=SC2029 # quote_arg makes each client-side expansion one remote word.
    {
        declare -f rig_lock_parent_claim_verify
        printf 'for i in {1..20}; do [ "$(cat "$RIG_LOCK_PARENT_PROOF" 2>/dev/null)" = "$RIG_LOCK_PARENT_CHALLENGE" ] && rig_lock_parent_claim_verify && exit; sleep .1; done; exit 1\n'
    } | ssh "${SSH_OPTS[@]}" "$host" "RIG_LOCK_PARENT_ACTOR=$(quote_arg "${RIG_LOCK_PARENT_ACTOR:-}") RIG_LOCK_PARENT_NONCE=$(quote_arg "${RIG_LOCK_PARENT_NONCE:-}") RIG_LOCK_PARENT_CHALLENGE=$(quote_arg "$challenge") RIG_LOCK_PARENT_PROOF=$(quote_arg "${RIG_LOCK_PARENT_PROOF:-/run/rig-e2e.proof}") RIG_LOCK_FILE=$(quote_arg "${RIG_LOCK_FILE:-/var/lock/rig-e2e.lock}") RIG_LOCK_HOLDER=$(quote_arg "${RIG_LOCK_HOLDER:-/run/rig-e2e.holder}") bash -s" || {
        warn "parent-held lock continuity failed on $host before $phase"
        return 1
    }
    step "parent-held lock verified on $host before $phase"
}

parent_lock_miner_borrow() {
    if [ -n "${RIG_LOCK_PARENT_ACTOR:-}" ] || [ -n "${RIG_LOCK_PARENT_NONCE:-}" ]; then
        parent_lock_checkpoint "loaner borrow" "$MINER_HOST" || return 1
        ok "parent rig lock verified on $MINER_HOST (loaner)"
    else
        rig_lock_remote pithead "e2e.sh loaner-borrow" "" "$MINER_HOST" "${SSH_OPTS[@]}"
        ok "rig lock held on $MINER_HOST (loaner) for the life of this run"
    fi
}

parent_lock_miner_restore() {
    [ "$BORROW_MINER" = 1 ] && { [ -n "${RIG_LOCK_PARENT_ACTOR:-}" ] || [ -n "${RIG_LOCK_PARENT_NONCE:-}" ]; } || return 0
    parent_lock_checkpoint "miner restore" "$MINER_HOST"
}
