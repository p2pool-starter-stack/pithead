# shellcheck shell=bash
# Observe the original SOCKS control, without another request or changed curl flags.
run_egress_socks_probe() {
    local tor_socks="$1" started=$SECONDS probe_rc=0 elapsed sequence exit_class record
    EGRESS_PROBE_SEQUENCE=$((${EGRESS_PROBE_SEQUENCE:-0} + 1))
    sequence=$EGRESS_PROBE_SEQUENCE
    if rx "docker exec monerod curl -s -o /dev/null -m 30 --socks5-hostname $tor_socks http://1.1.1.1/" >/dev/null 2>&1; then
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
    # Only harness-generated numbers and fixed vocabulary leave this function.
    # No endpoint, raw stderr, HTTP payload, cookie or later probe is retained.
    record="original-socks-probe sequence=$sequence exit=$probe_rc elapsed_s=$elapsed class=$exit_class stage=unknown"
    it_step "$record"
    if [ -n "${OUT_DIR:-}" ] && { mkdir -p "$OUT_DIR/tor-egress-probes" &&
        printf '%s\n' "$record" >"$OUT_DIR/tor-egress-probes/probe-$sequence.txt"; } 2>/dev/null; then
        :
    else
        it_step "original-socks-probe sequence=$sequence artifact unavailable; original status retained in transcript"
    fi
    return "$probe_rc"
}
