# shellcheck shell=bash
#
# The p2pool -> Tari merge-mining gRPC round-trip probe (#1397).
#
# WHY THIS EXISTS. Merge-mining is what makes Tari pay, and it is driven entirely by p2pool — a
# third-party binary — not by any client we wrote. `fakes/test_contract.py` looks like it covers
# this and does not: it drives the DASHBOARD's Tari client against `fake_tari.py`. Before this
# file, nothing at any tier observed p2pool reaching the Tari node, so a gRPC method moving
# behind an allow-list (the named risk on the Tari v5.6.0 bump, and the exact shape of #313)
# would land with every gate green.
#
# WHY TIER 4 AND NOT A FAKE. #1397 offered "drive p2pool's merge-mining client against a
# controllable fake" as the cheaper half that would also escape the sync problem. Measured at
# p2pool v4.18's source (the pinned binary we ship): there is exactly ONE creation site for
# merge-mining clients, `IMergeMiningClient::create`, and it sits inside the success callback of
# `download_block_headers4` — after `BLOCK_HEADERS_REQUIRED = 720` headers parse. So a fake would
# have to serve 720 consecutive, self-consistent Monero block headers and a live ZMQ publisher
# before the Tari fake is reached at all. That is not the cheaper half; it re-implements a synced
# monerod. Option 1 — a real box whose chain is already synced — is the one that works, and the
# release gate already runs on one.
#
# WHAT PROVES A ROUND-TRIP, AND WHAT ONLY LOOKS LIKE ONE. p2pool emits three lines. Two are
# LOCAL and prove only that the object was constructed and its threads spun:
#
#     MergeMiningClientTari event loop started
#     MergeMiningClientTari worker thread ready
#
# The third is the only assertion worth building on:
#
#     MergeMiningClientTari tari://<host:port> uses chain_id <id>
#
# because p2pool cannot know the chain_id without a successful call to the Tari node. Measured on
# the live stack, the two local lines land ~175 ms BEFORE the chain_id read, so asserting on
# either would be satisfiable with Tari unreachable — the false green this harness exists to
# kill. That is why `local-only` is its own verdict and a FAILURE, not a near-miss pass. It is
# also the most informative failure here: it says the client is up and Tari is not answering.
#
# THE LOG IS ANSI-COLOURED AND THE ESCAPES SIT MID-LINE. Measured with `cat -v` on the live
# stack, the chain_id line really reads:
#
#     ^[[0;90mMergeMiningClientTari ^[[0mtari://127.0.0.1:18142 uses chain_id ^[[0;96m01f0…
#
# `docker compose logs --no-color` suppresses DOCKER's colouring, not the application's own. A
# pattern written against the rendered text — `MergeMiningClientTari tari://.* uses chain_id` —
# therefore matches NOTHING, silently. That failure is invisible in the worst way: a probe that
# always reports "absent" looks identical to a working one right up to the moment it matters.
# Strip the escapes first, then match. The self-test carries the fired negative control.
#
# The signal belongs to one startup epoch, and prerequisite retries can delay it past any head cap.

MM_READY_TIMEOUT=120
MM_READY_INTERVAL=2
MM_CAPTURE_LINES=200
MM_CAPTURE_LINE_BYTES=2048
MM_RECENT_LINES=2000
MM_LOG_READ_TIMEOUT=15

mm_strip_ansi() { sed $'s/\033\\[[0-9;]*m//g'; }

# mm_roundtrip_verdict <log text> — prints exactly one of:
#
#   roundtrip <chain_id>  p2pool read a chain_id from the Tari node: the gRPC call SUCCEEDED
#   local-only            the client was constructed, but no chain_id was ever read
#   absent                p2pool never constructed a merge-mining client at all
#
# Returns 0 ONLY for roundtrip. PURE — a function of the text alone, so the self-test drives
# every class from a fixture with no stack, no container and no network.
mm_roundtrip_verdict() {
    local plain id
    plain="$(printf '%s\n' "$1" | mm_strip_ansi)"
    # `tail -n 1` takes the newest epoch should more than one ever reach this function. The
    # capture below already bounds the read to the current container run; this is the belt to
    # that braces, and it costs nothing.
    id="$(printf '%s\n' "$plain" |
        grep -aoE 'MergeMiningClientTari tari://[^ ]+ uses chain_id [0-9a-f]{16,}' |
        tail -n 1 | awk '{print $NF}')"
    if [ -n "$id" ]; then
        printf 'roundtrip %s\n' "$id"
        return 0
    fi
    if printf '%s\n' "$plain" | grep -qa 'MergeMiningClientTari'; then
        printf 'local-only\n'
        return 1
    fi
    printf 'absent\n'
    return 1
}

# The container's start time as a `--since` bound both engines' `compose logs` accept (#2326).
# Docker renders `.State.StartedAt` as RFC 3339 (`2026-09-20T05:54:04.957178532Z`) and passes
# through untouched. podman, the appliance's engine behind the podman-docker shim, renders it as
# Go's time.String() (`2026-09-20 05:54:04.957178532 +0000 UTC`), which docker-compose's client
# refuses before it sends any request. That refusal went to the `grep` below with the log, so the
# capture came back empty and every appliance run read "absent": job 69@90f47ed631's guest journal
# shows podman's API receiving no `/logs` request at all while the leg ran. Rewritten here to
# RFC 3339 with its offset, so the bound names the same instant on both engines.
mm_started() {
    local started
    started="$(rx "timeout ${MM_LOG_READ_TIMEOUT} docker inspect p2pool --format '{{.State.StartedAt}}'" 2>/dev/null)" || return 1
    started="$(printf '%s' "$started" | tr -d '\r')"
    [ -n "$started" ] || return 1
    printf '%s\n' "$started" | mm_rfc3339
}

# The container ID guards against a replacement that reuses StartedAt at the engine's precision.
mm_epoch() {
    local raw id started
    raw="$(rx "timeout ${MM_LOG_READ_TIMEOUT} docker inspect p2pool --format '{{.Id}}|{{.State.StartedAt}}'" 2>/dev/null)" || return 1
    raw="$(printf '%s' "$raw" | tr -d '\r')"
    id="${raw%%|*}"
    started="${raw#*|}"
    [ "$started" != "$raw" ] || return 1
    started="$(printf '%s\n' "$started" | mm_rfc3339)"
    [ -n "$id" ] && [ -n "$started" ] || return 1
    printf '%s|%s\n' "$id" "$started"
}

# stdin: a `.State.StartedAt`; stdout: the same instant as RFC 3339 (podman's form rewritten, Docker's
# passed through). podman's own `logs --since` refuses the Go form too (tests/os, #2333). PURE.
mm_rfc3339() {
    sed -E 's/^([0-9]{4}-[0-9]{2}-[0-9]{2}) ([0-9]{2}:[0-9]{2}:[0-9]{2}(\.[0-9]+)?) ([+-][0-9]{2})([0-9]{2}) .*$/\1T\2\4:\5/'
}

# Capture the CURRENT container run's merge-mining lines. Both bounds are load-bearing:
#
#   --since <StartedAt>  excludes any EARLIER startup epoch. Docker's restart policy can restart
#                        p2pool in place, and the log then still carries the old startup's
#                        chain_id line — which would satisfy this assertion while the live client
#                        never reached Tari. StartedAt moves with the restart; the log does not.
#   target-side filter  transfers a bounded tail of allowlisted lines plus the newest chain_id.
#
# `docker inspect` is used with --format naming ONE field. Unformatted, it prints `.Args`, which
# on this stack carries both wallet addresses, the RPC credential and the onion address; the same
# is true of the p2pool log's own argv line. Only lines matching MergeMiningClientTari cross the
# wire, so none of that is transferred here (#1582/#1585/#1586).
mm_capture_startup() { # [expected StartedAt]
    local started raw log_rc command
    started="${1:-$(mm_started)}"
    [ -n "$started" ] || return 1
    # The chain_id line is kept apart so chatter cannot evict it, and `cut` bounds a hostile line's length.
    command="timeout ${MM_LOG_READ_TIMEOUT} docker compose logs --no-color --since $(quote_arg "$started") p2pool 2>&1 | grep -a MergeMiningClientTari | awk -v n=${MM_CAPTURE_LINES} '/uses chain_id/{chain=\$0} {ring[NR%n]=\$0} END {if(chain!=\"\") print chain; first=(NR<n?1:NR-n+1); for(i=first;i<=NR;i++) print ring[i%n]}' | cut -c 1-${MM_CAPTURE_LINE_BYTES}; printf '\\n__PITHEAD_MM_LOG_RC=%s\\n' \"\${PIPESTATUS[0]}\""
    raw="$(rx "bash -c $(quote_arg "$command")" 2>/dev/null)" || return 2
    log_rc="$(printf '%s\n' "$raw" | sed -n 's/^__PITHEAD_MM_LOG_RC=//p' | tail -n 1)"
    [ "$log_rc" = 0 ] || return 2
    printf '%s\n' "$raw" | sed '/^__PITHEAD_MM_LOG_RC=/d'
}

# Prints `<verdict>|<epoch>`; returns 0 for a round-trip, 1 at the deadline, 2 on an unreadable epoch or log.
mm_await_roundtrip() {
    local deadline epoch after started lines verdict="absent" now
    epoch="$(mm_epoch)" || {
        printf 'start-error|\n'
        return 2
    }
    deadline=$(($(now_s) + MM_READY_TIMEOUT))
    while :; do
        started="${epoch#*|}"
        if ! lines="$(mm_capture_startup "$started")"; then
            printf 'read-error|%s\n' "$epoch"
            return 2
        fi
        after="$(mm_epoch)" || {
            printf 'start-error|%s\n' "$epoch"
            return 2
        }
        if [ "$after" != "$epoch" ]; then
            epoch="$after"
            verdict="epoch-changed"
        else
            verdict="$(mm_roundtrip_verdict "$lines")" || true
            case "$verdict" in roundtrip*)
                printf '%s|%s\n' "$verdict" "$epoch"
                return 0
                ;;
            esac
        fi
        now="$(now_s)"
        [ "$now" -ge "$deadline" ] && break
        sleep "$MM_READY_INTERVAL"
    done
    printf '%s|%s\n' "$verdict" "$epoch"
    return 1
}

mm_startup_lost() {
    local started oldest
    started="$(mm_started)" || return 1
    oldest="$(rx "timeout ${MM_LOG_READ_TIMEOUT} docker logs --timestamps --since $(quote_arg "$started") p2pool 2>&1 | head -n 1 | awk '\$1 ~ /^[0-9][0-9][0-9][0-9]-/ {print \$1}'" 2>/dev/null)" || return 1
    python3 - "$started" "$oldest" <<'MM_TIME'
import re
import sys
from datetime import datetime
from decimal import Decimal


def instant(text):
    match = re.fullmatch(r"(\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2})(?:\.(\d{1,9}))?(Z|[+-]\d{2}:\d{2})", text)
    if not match:
        raise ValueError("invalid engine timestamp")
    whole = datetime.fromisoformat(match[1] + match[3].replace("Z", "+00:00"))
    return whole, Decimal("0." + (match[2] or "0"))


try:
    (start, sf), (oldest, of) = map(instant, sys.argv[1:])
    lost = Decimal(str((oldest - start).total_seconds())) + of - sf > 60
except ValueError:
    lost = False
sys.exit(0 if lost else 1)
MM_TIME
}

mm_capture_recent() {
    rx "timeout ${MM_LOG_READ_TIMEOUT} docker compose logs --no-color --since 60s p2pool 2>&1 | tail -n ${MM_RECENT_LINES} | grep -a MergeMiningClientTari | cut -c 1-${MM_CAPTURE_LINE_BYTES} || true" 2>/dev/null
}

MM_EXCERPT_LINES=80
MM_EXCERPT_KEEP='error|fail|refus|invalid|unknown|cannot|denied|timed out|timeout|no such|tari|p2pool-entrypoint'
mm_startup_excerpt() {
    local started
    # shellcheck disable=SC2034  # read by redact_remote_output through dynamic scope
    local REMOTE_NODE_HOSTS=("${REMOTE_MONERO_HOST:-}" "${REMOTE_TARI_HOST:-}")
    started="$(mm_started)" || return 0
    rx "timeout ${MM_LOG_READ_TIMEOUT} docker compose logs --no-color --since $(quote_arg "$started") p2pool 2>&1 | grep -aiE '${MM_EXCERPT_KEEP}' | tail -n ${MM_EXCERPT_LINES} | cut -c 1-${MM_CAPTURE_LINE_BYTES} || true" 2>/dev/null |
        mm_strip_ansi | redact_remote_output | mm_mask_excerpt
}

# The excerpt's own masks, over redact(), which is keyed on flag and JSON shapes and cannot see a
# secret written in prose. In order: every IPv4; anything IPv6-shaped (log timestamps match too
# and are masked with them — the cost of not guessing); a `name:value` or `name=value` token, which is how a
# credential reads in prose (a `scheme://` URL and a `label: text` pair are left alone), with `=`-padded
# base64 masked first so its padding is not read as an assignment; and any
# 40+ character alphanumeric run, since a Tari address's length is not pinned anywhere here. PURE.
mm_mask_excerpt() {
    sed -E 's/[0-9]{1,3}(\.[0-9]{1,3}){3}/<ip>/g
        s/[0-9A-Fa-f]{0,4}(:[0-9A-Fa-f]{0,4}){2,7}/<ip>/g
        s/[A-Za-z0-9_.-]*[A-Za-z][A-Za-z0-9_.-]*:[^[:space:]\/][^[:space:]]*/<redacted>/g
        s/[A-Za-z0-9+\/]{16,}={1,2}/<redacted>/g
        s/([A-Za-z0-9_.-]+)=[^[:space:]]+/\1=<redacted>/g
        s/[A-Za-z0-9]{40,}/<redacted-address>/g
        s/^/          /'
}

assert_mergemine_roundtrip() {
    local observed verdict epoch current lines rc=0 excerpt=""
    observed="$(mm_await_roundtrip)" || rc=$?
    case "$rc" in
    2)
        verdict="${observed%%|*}"
        it_fail "p2pool merge-mining gRPC round-trip (#1397)" "could not read p2pool's current container epoch or its logs (${verdict})"
        return 0
        ;;
    esac
    verdict="${observed%%|*}"
    epoch="${observed#*|}"
    case "$verdict" in absent | local-only)
        if mm_startup_lost; then
            current="$(mm_epoch)" || current=""
            if [ "$current" = "$epoch" ]; then
                lines="$(mm_capture_recent)" || lines=""
                current="$(mm_epoch)" || current=""
                if [ "$current" != "$epoch" ]; then
                    it_fail "p2pool merge-mining gRPC round-trip (#1397)" "p2pool restarted during the fresh-window read; refusing a verdict from the prior container epoch"
                elif verdict="$(mm_roundtrip_verdict "$lines")"; then
                    it_pass "p2pool reached the Tari node over gRPC — fresh ${verdict} (#1397)"
                else
                    it_skip_leg "p2pool merge-mining gRPC round-trip (#1397)" \
                        "oldest retained log timestamp is more than 60 seconds after container start; startup evidence may have been lost (conservative heuristic), and no fresh round-trip proof is available" missing
                fi
                return 0
            fi
        fi
        ;;
    esac
    if [ "$verdict" = absent ] && ! monero_caught_up; then
        current="$(mm_epoch)" || current=""
        if [ "$current" = "$epoch" ]; then
            it_skip_leg "p2pool merge-mining gRPC round-trip (#1397)" \
                "p2pool built no merge-mining client and monerod could not be confirmed caught up — p2pool constructs the client only after the block-header download succeeds, so the signal cannot exist on this run" by-design
        else
            it_fail "p2pool merge-mining gRPC round-trip (#1397)" "p2pool restarted after the absent observation; refusing a stale prerequisite skip from the prior container epoch"
        fi
        return 0
    fi
    case "$verdict" in roundtrip*)
        current="$(mm_epoch)" || current=""
        if [ "$current" != "$epoch" ]; then
            it_fail "p2pool merge-mining gRPC round-trip (#1397)" "p2pool restarted after the chain_id observation; refusing a stale success from the prior container epoch"
            return 0
        fi
        ;;
    epoch-changed)
        it_fail "p2pool merge-mining gRPC round-trip (#1397)" "p2pool restarted at the readiness deadline; the new container epoch was not observed"
        return 0
        ;;
    *) excerpt="
        diagnostic lines from this run's startup log (allowlisted, at most ${MM_EXCERPT_LINES}, redacted):
$(mm_startup_excerpt)" ;;
    esac
    case "$verdict" in
    roundtrip*) it_pass "p2pool reached the Tari node over gRPC — ${verdict} (#1397)" ;;
    local-only)
        it_fail "p2pool merge-mining gRPC round-trip (#1397)" \
            "p2pool built its merge-mining client but never read a chain_id — the client is up and Tari is NOT answering${excerpt}"
        ;;
    *)
        it_fail "p2pool merge-mining gRPC round-trip (#1397)" \
            "no MergeMiningClientTari line appeared within ${MM_READY_TIMEOUT}s in the current container epoch — p2pool built no merge-mining client${excerpt}"
        ;;
    esac
}
