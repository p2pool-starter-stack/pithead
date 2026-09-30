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
# THE SIGNAL IS STARTUP-ONLY. The three lines land within ~17.5s of the container's start — at
# positions 68/69/71 of a log that had reached 83,070 lines after 30h (ONE sample, live stack,
# 2026-08-30). `--tail 200` cannot contain them on a container that has been up minutes, so this
# read is bounded by the container's own StartedAt and a head window, never by a tail.

# The startup window, in lines. The observed maximum position is 71 (one sample), so 2000 is
# ~28x headroom while still being two orders below a day-old log — "startup" stays a real bound
# rather than a name. It is a CEILING, not a cost: `head` closes the pipe, and only the matching
# lines ever cross the wire.
MM_WINDOW_LINES=2000

# Strip SGR escape sequences. PURE.
# The ESC byte is written with bash ANSI-C quoting rather than a `\x1b` inside the sed script,
# because that spelling depends on the sed implementation and this box's text tools are shims.
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
    started="$(rx "docker inspect p2pool --format '{{.State.StartedAt}}'" 2>/dev/null | tr -d '\r')"
    [ -n "$started" ] || return 1
    printf '%s\n' "$started" | mm_rfc3339
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
#   head -n <window>     keeps this a startup read rather than a whole-log scan.
#
# `docker inspect` is used with --format naming ONE field. Unformatted, it prints `.Args`, which
# on this stack carries both wallet addresses, the RPC credential and the onion address; the same
# is true of the p2pool log's own argv line. Only lines matching MergeMiningClientTari cross the
# wire, so none of that is transferred here (#1582/#1585/#1586).
mm_capture_startup() {
    local started
    started="$(mm_started)" || return 1
    rx "docker compose logs --no-color --since $(quote_arg "$started") p2pool 2>&1 | head -n ${MM_WINDOW_LINES} | grep -a MergeMiningClientTari || true" 2>/dev/null
}

# Diagnostic lines from the same window, for a FAIL only (#2326). An empty capture cannot say
# whether p2pool built no client, the client could not reach Tari, or the log was never read; these
# lines can: a `compose logs` error, the entrypoint's launch and bridge lines, p2pool's Tari and error
# lines. The log itself carries both wallets, the RPC credential and the onion, and p2pool's own
# startup format is not captured anywhere in this repo, so the filter is an ALLOWLIST applied on the
# target: only matching lines cross the wire. What crosses is then passed through redact(), with this
# run's remote endpoints and every IPv4 address masked, private ranges included.
MM_EXCERPT_LINES=80
MM_EXCERPT_KEEP='error|fail|refus|invalid|unknown|cannot|denied|timed out|timeout|no such|tari|p2pool-entrypoint'
mm_startup_excerpt() {
    local started
    # shellcheck disable=SC2034  # read by redact_remote_output through dynamic scope
    local REMOTE_NODE_HOSTS=("${REMOTE_MONERO_HOST:-}" "${REMOTE_TARI_HOST:-}")
    started="$(mm_started)" || return 0
    rx "docker compose logs --no-color --since $(quote_arg "$started") p2pool 2>&1 | head -n ${MM_WINDOW_LINES} | grep -aiE '${MM_EXCERPT_KEEP}' | head -n ${MM_EXCERPT_LINES} || true" 2>/dev/null |
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

# The release-gate leg: PASS, FAIL, or an honest counted SKIP — never a silent green.
#
# THE CAPTURE IS READ BEFORE THE PREDICATE, AND THAT ORDER IS ITSELF AN ASSERTION (#1597).
# `monero_caught_up` REDUCED several independent conditions to one bit: its `curl -fsS` discards
# stderr and leaves the body EMPTY on an unreachable RPC, a refused connection or a 401, and
# `jq -e` over an empty body answered exactly as it does for a node that is genuinely behind.
# #1605 has since split that bit three ways — 0 caught up, 1 answered-and-behind, any other rc
# could-not-ask — but THIS SITE DELIBERATELY TAKES BOTH NONZERO DOORS: `! monero_caught_up` below
# is true for each, and the skip's own text says "could not be confirmed caught up", which is a
# true statement about both. The capture-first order, not the predicate's precision, is what keeps
# this skip honest; narrowing the test to `= 1` here would make the leg red on an unreachable RPC
# in the one case p2pool has already proved the signal cannot exist.
# Asked first, that one bit decided the whole leg — so a stack whose monerod was synced and whose
# merge-mining client was up and reading chain_ids would have been booked as an ACCEPTED HOLE for
# as long as the RPC stayed unanswerable. That state is not hypothetical here — `lib.sh`'s
# env_bake_verdict comment records a day of it; read the incident there, not a second copy of it.
# The capture answers the question the predicate was standing in for, and answers it from p2pool
# rather than from the RPC we could not reach: p2pool constructs a MergeMiningClientTari only
# after its block-header download succeeds, so ANY such line is proof that monerod caught up.
#
# The skip stays classed `by-design` rather than `missing` on the skip-accounting test, and
# reading the capture first is what makes that class honest rather than merely conventional. It
# is now reached only when the startup window WAS read and held no merge-mining line at all — so
# p2pool built no client, so the header download did not complete, so no input, flag or env var
# to THIS harness would make the signal exist (cycle 40 measured zero Tari gRPC calls across five
# legs against absent, synced-fake and partial-fake monerods). Covering it means running against
# a synced chain, not supplying something.
#
# Every case the reorder moves, it moves OUT of the skip ledger into a pass or a fail; no case
# that previously passed or failed can become a skip. That direction is the safety argument, and
# the self-test asserts all three moved cases rather than resting on it.
assert_mergemine_roundtrip() {
    local lines verdict excerpt=""
    if ! lines="$(mm_capture_startup)"; then
        it_fail "p2pool merge-mining gRPC round-trip (#1397)" "could not read p2pool's container start time"
        return 0
    fi
    if [ -z "$lines" ] && ! monero_caught_up; then
        it_skip_leg "p2pool merge-mining gRPC round-trip (#1397)" \
            "p2pool built no merge-mining client and monerod could not be confirmed caught up — p2pool constructs the client only after the block-header download succeeds, so the signal cannot exist on this run" by-design
        return 0
    fi
    verdict="$(mm_roundtrip_verdict "$lines")" || excerpt="
        diagnostic lines from this run's startup log (allowlisted, at most ${MM_EXCERPT_LINES}, redacted):
$(mm_startup_excerpt)"
    case "$verdict" in
    roundtrip*) it_pass "p2pool reached the Tari node over gRPC — ${verdict} (#1397)" ;;
    local-only)
        it_fail "p2pool merge-mining gRPC round-trip (#1397)" \
            "p2pool built its merge-mining client but never read a chain_id — the client is up and Tari is NOT answering${excerpt}"
        ;;
    *)
        it_fail "p2pool merge-mining gRPC round-trip (#1397)" \
            "no MergeMiningClientTari line in the first ${MM_WINDOW_LINES} lines after the container started — p2pool built no merge-mining client, or the log could not be read${excerpt}"
        ;;
    esac
}
