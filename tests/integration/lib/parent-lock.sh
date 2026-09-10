# shellcheck shell=bash
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
