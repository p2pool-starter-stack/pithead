# shellcheck shell=bash
TARI_DATA=""
TARI_SNAPSHOT_ROOT=""
TARI_SNAPSHOT_READY=0

select_tari_data() {
    [ -z "$TARI_DATA" ] && [ "$1" = snapshot ] || die "--tari-data accepts snapshot once."
    TARI_DATA=$1
}

validate_tari_data() {
    [ -z "$TARI_DATA" ] && return 0
    [ "$TARI_DATA" = snapshot ] || die "--tari-data must be snapshot."
    [ "$MODE" != check ] && [ "$KEEP" = 0 ] || die "--tari-data snapshot requires deployment and restoration."
    [[ "${CI_JOB_ID:-}" =~ ^[1-9][0-9]*$ && "${CI_COMMIT:-}" =~ ^[0-9a-f]{40}$ ]] &&
        [ -n "${CI_TARI_SNAPSHOT_RESTORE_STATE:-}" ] && [ -n "${IT_SCRATCH_DIR:-}" ] || die "--tari-data snapshot requires the bench-ci restoration contract."
}

tari_snapshot_receipt() {
    [ -n "$TARI_DATA" ] || return 0
    on_bench "python3 - receipt $(quote_arg "$CI_TARI_SNAPSHOT_RESTORE_STATE") $(quote_arg "$CI_JOB_ID") $(quote_arg "$CI_COMMIT") ${1:+$(quote_arg "$1")}" <"$HERE/lib/tari-snapshot-state.py"
}

tari_snapshot_action() {
    on_bench "bash $(quote_arg "$TARI_SNAPSHOT_ROOT/tari-snapshot-target.sh") $(quote_arg "$TARI_SNAPSHOT_ROOT") $(quote_arg "$1")"
}

tari_snapshot_capture() {
    [ -n "$TARI_DATA" ] || return 0
    [ "$(tari_snapshot_receipt)" = ARMED ] || die "Tari snapshot receipt is not armed."
    TARI_SNAPSHOT_ROOT="$(on_bench "umask 077; mktemp -d $(quote_arg "$IT_SCRATCH_DIR/tari-snapshot.XXXXXX")")" || die "Tari snapshot scratch unavailable."
    case "$TARI_SNAPSHOT_ROOT" in "$IT_SCRATCH_DIR"/tari-snapshot.*) ;; *) die "Tari snapshot scratch identity invalid." ;; esac
    local file
    for file in live-state-support.sh tari-snapshot-state.py tari-snapshot-target.sh; do
        on_bench "umask 077; cat >$(quote_arg "$TARI_SNAPSHOT_ROOT/$file")" <"$HERE/lib/$file" || die "Cannot install Tari snapshot worker."
    done
    tari_snapshot_receipt NOT_PROVEN >/dev/null || die "Cannot durably fence Tari snapshot restoration."
    on_bench "python3 $(quote_arg "$TARI_SNAPSHOT_ROOT/tari-snapshot-state.py") identity $(quote_arg "$TARI_SNAPSHOT_ROOT") $(quote_arg "$CI_TARI_SNAPSHOT_RESTORE_STATE") $(quote_arg "$CI_JOB_ID") $(quote_arg "$CI_COMMIT")" || die "Cannot bind snapshot recovery identity."
    TARI_SNAPSHOT_READY=1
    tari_snapshot_action capture || die "Tari snapshot capture refused; branch not deployed."
    on_bench "nohup python3 $(quote_arg "$TARI_SNAPSHOT_ROOT/tari-snapshot-state.py") observe $(quote_arg "$TARI_SNAPSHOT_ROOT") >$(quote_arg "$TARI_SNAPSHOT_ROOT/observer.log") 2>&1 </dev/null & echo \$! >$(quote_arg "$TARI_SNAPSHOT_ROOT/observer.pid")" || die "Cannot start Tari snapshot observer."
    ok "Tari pre-run node and wallet data captured in private snapshots"
}

tari_snapshot_before_restore() {
    [ -n "$TARI_DATA" ] || return 0
    [ "$TARI_SNAPSHOT_READY" = 1 ] && tari_snapshot_action restore || {
        tari_snapshot_receipt NOT_PROVEN >/dev/null || true
        warn "Tari snapshot restoration NOT PROVEN; retain recovery reservations and snapshots."
        return 1
    }
}

tari_snapshot_branch() {
    [ -n "$TARI_DATA" ] || return 0
    tari_snapshot_action branch || die "Tari snapshot branch marker was not established."
    on_bench "python3 $(quote_arg "$TARI_SNAPSHOT_ROOT/tari-snapshot-state.py") report $(quote_arg "$TARI_SNAPSHOT_ROOT")" || die "Tari snapshot observations unavailable."
}

tari_snapshot_verify() {
    [ -n "$TARI_DATA" ] || return 0
    tari_snapshot_action verify && tari_snapshot_action cleanup && tari_snapshot_receipt VERIFIED >/dev/null || {
        warn "Tari snapshot restoration NOT PROVEN; retain recovery reservations and snapshots."
        return 1
    }
    ok "restore proof: baseline Tari opened the pre-run snapshot; branch marker absent"
}
