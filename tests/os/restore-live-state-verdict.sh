# shellcheck shell=bash
#
# Shared by tests/os/run.sh's phase_install restore leg (drives it against a real KVM guest's
# `podman ps` + `podman inspect p2pool`) and tests/stack/run.sh's fixture unit test (drives it
# against canned strings): the restore leg's closing verdict, #1091. `config.json` landing on the
# restored disk proves only that the ARCHIVE was UNPACKED — it is a grep of a file the restore
# itself just wrote, true even if the stack never came back up under the restored config, exactly
# like #971 closed on the DIY channel (tests/integration/run.sh reads .pool.type out of LIVE
# state after restore+up). This pairs two live observations instead of the archived file: the
# stack containers actually running, and a value SOURCED FROM the restored config appearing in
# configured state — the --wallet argument the stack's start path rendered into the container
# (`podman inspect p2pool`'s .Config.Cmd), not a re-read of the archive. Not p2pool's stratum
# stats (/api/state's .stratum.wallet): p2pool writes those only once a SYNCED monerod hands it a
# block template, and a restored guest boots a fresh chain, so that source failed by construction
# on the first live battery run (#1662).

# $1 = `podman ps --format '{{.Names}}'` output (space/newline-joined; may be empty/unreachable)
# $2 = the created p2pool container's --wallet argument (empty/"Unknown"/"null" all count
#      as unreadable — the two words are what the earlier /api/state source returned when absent)
# $3 = the wallet address the ORIGINAL backup was taken from
# Prints the verdict line on stdout; exit 0 = pass, 1 = fail.
restore_live_state_verdict() {
    local names="$1" live_wallet="$2" want="$3"
    case "$names" in
    *dashboard*caddy* | *caddy*dashboard*) ;;
    *)
        echo "the stack never came up on the restored machine (podman ps: '${names:-none}') — config.json on disk is not proof the machine is RUNNING what was restored (#1091)"
        return 1
        ;;
    esac
    case "$live_wallet" in
    "" | Unknown | null)
        echo "the stack is up but live state never carried a readable stratum wallet (got '${live_wallet:-none}')"
        return 1
        ;;
    esac
    if [ "$live_wallet" != "$want" ]; then
        echo "the stack is up but live state's wallet is '$live_wallet', not the restored '$want' — the restore landed a file but the running stack does not reflect it (#1091)"
        return 1
    fi
    echo "the restored container's configured wallet matches the archive; daemon startup is checked separately"
    return 0
}

# The restore must first prove its normal sync-gate hold. Pause only its controller during this
# 30-second startup probe, since it would otherwise stop P2Pool every poll on fresh chains.
# Start the existing restored container once, never retry it, then restore the normal gate.
restore_p2pool_startup() {
    local state id running exit_code restarts oom extra started_at stop_logs line initial_id="" sample failed=0 checkpoint="stop dashboard"
    local inspect="podman inspect p2pool --format '{{.Id}} {{.State.Running}} {{.State.ExitCode}} {{.RestartCount}} {{.State.OOMKilled}}'"
    _ssh "podman stop dashboard >/dev/null" || failed=1
    if [ "$failed" -eq 0 ]; then
        checkpoint="inspect prior state"
        state=$(_ssh "$inspect") || failed=1
        read -r initial_id running exit_code restarts oom extra <<<"$state"
        [ "$failed" -ne 0 ] || checkpoint="validate prior state"
        # Reject earlier crashes and OOM kills. A proven sync-gate stop may escalate SIGTERM
        # to SIGKILL (137) while P2Pool waits for a remote curl job; require this run's stop logs.
        [ -n "$initial_id" ] && { [ "$running" = true ] || [ "$running" = false ]; } &&
            [ "$restarts" = 0 ] && [ "$oom" = false ] && [ -z "$extra" ] || failed=1
        if [ "$exit_code" = 137 ] && [ "$running" = false ] && [ "$failed" -eq 0 ]; then
            checkpoint="read prior start time"
            started_at=$(_ssh "podman inspect p2pool --format '{{.State.StartedAt}}'") || failed=1
            started_at=$(printf '%s\n' "$started_at" | mm_rfc3339)
            [ "$failed" -ne 0 ] || checkpoint="validate prior start time"
            [[ "$started_at" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9:.]+(Z|[+-][0-9]{2}:[0-9]{2})$ ]] || failed=1
            if [ "$failed" -eq 0 ]; then
                checkpoint="read prior stop logs"
                stop_logs=$(_ssh "podman logs --since '$started_at' --tail 30 p2pool 2>&1") || failed=1
                [ "$failed" -ne 0 ] || checkpoint="validate prior stop logs"
                [[ "$stop_logs" = *'P2Pool caught SIGTERM'* ]] && [[ "$stop_logs" = *'P2Pool stopping'* ]] || failed=1
            fi
        else
            [ "$exit_code" = 0 ] || failed=1
        fi
    fi
    if [ "$failed" -eq 0 ]; then
        checkpoint="start P2Pool"
        _ssh "podman start p2pool >/dev/null" || failed=1
    fi
    for sample in 0 1 2 3; do
        [ "$failed" -eq 0 ] || break
        checkpoint="observe sample $sample"
        if [ "$sample" -ne 0 ] && ! sleep 10; then
            failed=1
            break
        fi
        state=$(_ssh "$inspect") || failed=1
        read -r id running exit_code restarts oom extra <<<"$state"
        [ "$id" = "$initial_id" ] && [ "$running" = true ] && [ "$exit_code" = 0 ] &&
            [ "$restarts" = 0 ] && [ "$oom" = false ] && [ -z "$extra" ] || failed=1
    done
    # Always restore controller ownership, including after a transport/start/inspect failure.
    if ! _ssh 'podman stop p2pool >/dev/null; stopped=$?; podman start dashboard >/dev/null && test "$stopped" -eq 0'; then
        checkpoint="$checkpoint; controller restoration"
        failed=1
    fi
    if [ "$failed" -ne 0 ]; then
        echo "P2Pool startup or controller restoration failed at $checkpoint (state: ${state:-unreadable})" | cut -c 1-240 >&2
        printf 'prior start time: %q\n' "${started_at:-unreadable}" | cut -c 1-240 >&2
        # Keep escape sequences visible when a raw daemon line fails the stop-log predicate.
        printf '%s\n' "${stop_logs:-no prior stop logs}" | head -30 | while IFS= read -r line; do
            printf '%q\n' "$line" | cut -c 1-240 >&2
        done
        _ssh "podman logs --tail 30 p2pool 2>&1; journalctl -k -b -n 200 --no-pager | grep -E 'p2pool.*(fault|segfault)' | tail -10" >&2 || true
    fi
    [ "$failed" -eq 0 ]
}
