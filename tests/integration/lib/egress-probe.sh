# shellcheck shell=bash
# shellcheck source=tests/integration/lib/tor-control-dial.sh
source "${BASH_SOURCE[0]%/*}/tor-control-dial.sh" || return $?

_egress_socks_attempt() {
    local tor_socks="$1" attempt="$2" started=$SECONDS probe_rc=0 elapsed sequence exit_class record label
    EGRESS_PROBE_SEQUENCE=$((${EGRESS_PROBE_SEQUENCE:-0} + 1))
    sequence=$EGRESS_PROBE_SEQUENCE
    if rx "$(tor_control_dial_cmd docker curl "$tor_socks" "$attempt")" >/dev/null 2>&1; then
        probe_rc=0
    else
        probe_rc=$?
    fi
    elapsed=$((SECONDS - started))
    # rx returns the target status, or SSH's status if transport fails. Never call
    # 255 a curl diagnosis. Silent curl supplies no error text or request-stage timings.
    case "$probe_rc" in
    0) exit_class=completed ;;
    7) exit_class=connect-failed ;;
    28) exit_class=timeout-stage-unknown ;;
    52) exit_class=empty-reply ;;
    56) exit_class=receive-or-socks-failed ;;
    97) exit_class=proxy-handshake-failed ;;
    125 | 126 | 127) exit_class=execution-failed ;;
    255) exit_class=target-or-ssh-failed ;;
    *) exit_class=unclassified ;;
    esac
    label=original-socks-probe
    [ "$attempt" -eq 1 ] || label=retry-socks-probe
    record="$label sequence=$sequence exit=$probe_rc elapsed_s=$elapsed class=$exit_class stage=unknown"
    [ "$attempt" -eq 1 ] || record="$record attempt=$attempt"
    EGRESS_PROBE_CLASS=$exit_class
    it_step "$record"
    if [ -n "${OUT_DIR:-}" ] && { mkdir -p "$OUT_DIR/tor-egress-probes" &&
        printf '%s\n' "$record" >"$OUT_DIR/tor-egress-probes/probe-$sequence.txt"; } 2>/dev/null; then
        :
    else
        it_step "$label sequence=$sequence artifact unavailable; original status retained in transcript"
    fi
    return "$probe_rc"
}

run_egress_socks_probe() {
    local attempt=1 probe_rc=0 failed=""
    # shellcheck disable=SC2034 # read by assert_egress_dial_pair
    EGRESS_PROBE_SUMMARY=""
    while [ "$attempt" -le "$TOR_CONTROL_DIAL_ATTEMPTS" ]; do
        probe_rc=0
        _egress_socks_attempt "$1" "$attempt" || probe_rc=$?
        if [ "$probe_rc" -eq 0 ]; then
            [ "$attempt" -eq 1 ] ||
                EGRESS_PROBE_SUMMARY="passed on attempt $attempt of $TOR_CONTROL_DIAL_ATTEMPTS; $failed"
            return 0
        fi
        failed="${failed:+$failed; }attempt $attempt exit=$probe_rc class=$EGRESS_PROBE_CLASS"
        attempt=$((attempt + 1))
    done
    # shellcheck disable=SC2034 # read by assert_egress_dial_pair
    EGRESS_PROBE_SUMMARY="all $TOR_CONTROL_DIAL_ATTEMPTS attempts failed; $failed"
    return "$probe_rc"
}
