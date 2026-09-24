#!/usr/bin/env bash
#
# Self-test for support-bundle's `.env` redactor (#1631, ruled on #1630).
#
# THE INVERSION. Before this change, both `.env` consumers ran a DENYLIST — a suffix or substring
# match over a vocabulary someone else keeps extending by adding `render_env` keys. That failed
# four times (#1596, #1609, #1611, #1621), every time in the unsafe direction, and the two
# consumers disagreed on 17 of 129 keys because one matched a SUFFIX and the other an unanchored
# SUBSTRING. `bundle_redact_env` (07-support-bundle.sh) inverts to an ALLOWLIST of survivors: a
# key absent from PITHEAD_ENV_SURVIVOR_KEYS is redacted, so an unclassified `render_env` addition
# is safe by construction rather than an invisible leak.
#
# THE FOUR KEYS THE PRE-INVERSION MEASUREMENT CAUGHT IN THE CLEAR (issue #1631, the population
# audit comment): `NTFY_URL` and `NOTIFY_WEBHOOK_URLS` are capability URLs, `MONERO_NODE_USERNAME`
# is half of the monerod RPC credential pair (the bundle redacted the password but not the
# username), and `XVB_DONOR_ID` resolves to the first 8 characters of the operator's wallet
# address on `auto` (33-render-env.sh). Named as their own rows below, not folded into the sweep,
# because a regression here is the concrete leak this issue exists to close.
#
# HOW THIS FILE MEASURES. The population is READ OUT of `render_env`'s heredoc, never restated —
# a copy pasted into this file is exactly the drift an allowlist over someone else's population is
# meant to catch. Every key gets a hand classification below (MUST_REDACT / MUST_SURVIVE); a
# population key in neither list fails BY NAME, so a new `render_env` key forces a review here
# even though the shipped default (redact) is already safe. Each row runs the REAL, BUILT
# `bundle_redact_env`, never a paraphrase of its rule.
#
# Every fixture is synthetic. The binding assertion for a redacted key is that the RAW value is
# ABSENT, never that a `[redacted]` marker appeared — a marker can come from another field on the
# same line, though this filter only ever sees one KEY=value pair at a time.
#
# Run: tests/integration/selftest/selftest-bundle-redact-env.sh
#
set -uo pipefail

HERE="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=tests/integration/lib.sh
source "$HERE/../lib.sh"

REPO="$(cd -P "$HERE/../../.." && pwd -P)"
RENDER="$REPO/lib/pithead/33-render-env.sh"

# Run the SHIPPED function in a subshell, so sourcing the artifact cannot leak definitions into
# this harness. `source` reads from /dev/null so it can never consume the payload on stdin.
bre() { (
    source "$REPO/pithead" </dev/null >/dev/null 2>&1
    bundle_redact_env
); }

# --- ARMING -----------------------------------------------------------------------------------
# Without this, a broken source makes every absence assertion below pass vacuously.
echo "== unit: support-bundle env redactor is reachable (#1631) =="
if (
    source "$REPO/pithead" </dev/null >/dev/null 2>&1
    declare -F bundle_redact_env >/dev/null
); then
    it_pass "bundle_redact_env is defined by the built pithead"
else
    it_fail "bundle_redact_env is defined by the built pithead" \
        "source failed or the function is absent — every row below would pass vacuously"
    exit 1
fi
if [ -n "$(printf 'STRATUM_PORT=3333\n' | bre)" ]; then
    it_pass "the redactor emits a survivor line (the harness can observe a value at all)"
else
    it_fail "the redactor emits a survivor line (the harness can observe a value at all)" \
        "empty output — an absence assertion against this is meaningless"
    exit 1
fi

# --- THE FOUR KEYS THE PRE-INVERSION AUDIT FOUND LEAKING (issue #1631) ------------------------
echo "== unit: the four keys the pre-inversion bundle left in the clear are now redacted (#1631) =="
for _key in NTFY_URL NOTIFY_WEBHOOK_URLS MONERO_NODE_USERNAME XVB_DONOR_ID; do
    OUT="$(printf '%s=SENTINELVALUE\n' "$_key" | bre)"
    case "$OUT" in
    *SENTINELVALUE*) it_fail "$_key is redacted" "raw value survived: $OUT" ;;
    *) it_pass "$_key is redacted" ;;
    esac
done

# --- WHICH LINES ARE READ (#2414) --------------------------------------------------------------
# The filter used to look only at lines matching `^[A-Z][A-Z0-9_]*=` and print everything else
# verbatim, so the previous password a hand-edited .env keeps commented out above the live one
# shipped in the clear. Each variant below carries a distinct value, so a failure names the shape
# that leaked. Ruled on the issue: every ambiguity fails closed, so a secret anywhere in comment
# prose, after a survivor's value or behind an unclosed quote is redacted too.
echo "== unit: commented, indented and malformed secret lines are redacted (#2414) =="
while IFS='|' read -r _label _line; do
    OUT="$(printf '%s\n' "$_line" | bre)"
    case "$OUT" in
    *OLDSECRET*) it_fail "$_label is redacted" "raw value survived: $OUT" ;;
    *) it_pass "$_label is redacted" ;;
    esac
done <<'ROWS'
active assignment|MONERO_NODE_PASSWORD=OLDSECRET1
commented assignment|# MONERO_NODE_PASSWORD=OLDSECRET2
commented, no space|#MONERO_NODE_PASSWORD=OLDSECRET3
double-hash comment|## TELEGRAM_BOT_TOKEN=OLDSECRET4
indented assignment|    WALLET_RPC_PASSWORD=OLDSECRET5
tab-indented comment|	#	PROXY_AUTH_TOKEN=OLDSECRET6
export prefix|export NTFY_TOKEN=OLDSECRET7
commented export|# export XMRIG_API_TOKEN=OLDSECRET8
spaces around =|TARI_WALLET_PASSWORD = OLDSECRET9
lowercase key|monero_node_password=OLDSECRET10
malformed, no =|MONERO_NODE_PASSWORD OLDSECRET11
malformed, empty key|=OLDSECRET12
malformed, bare value|OLDSECRET13
secret inside comment prose|# rotated; see WALLET_RPC_PASSWORD=OLDSECRET14 for the old one
second secret in comment prose|# STRATUM_PORT is 3333, NTFY_TOKEN=x and TELEGRAM_BOT_TOKEN = OLDSECRET15
trailing comment on a survivor|STRATUM_PORT=3333 # old MONERO_NODE_PASSWORD=OLDSECRET16
trailing prose on a survivor|MONERO_WALLET_RPC_URL=http://127.0.0.1:18082/json_rpc # pw OLDSECRET17
second KEY= on a survivor|STRATUM_PORT=3333 MONERO_NODE_PASSWORD=OLDSECRET18
second KEY= on a commented survivor|# STRATUM_PORT=3334 MONERO_NODE_PASSWORD=OLDSECRET19
unclosed quote on a survivor|STRATUM_BIND="0.0.0.0 OLDSECRET20
second KEY= after a comma|HOST_PORT=80,WALLET_RPC_PASSWORD=OLDSECRET21
second KEY= glued on|HOST_PORT=80WALLET_RPC_PASSWORD=OLDSECRET22
second KEY= glued on, in prose|# was HOST_PORT=3333WALLET_RPC_PASSWORD=OLDSECRET23
second KEY= after a comma, in prose|# was HOST_PORT=3333,WALLET_RPC_PASSWORD=OLDSECRET24
ROWS

# Fail closed must not become fail useless: the operational keys the bundle exists to carry stay
# readable through every new path, including the double-quoted form dotenv_render_value writes.
echo "== unit: survivor values stay readable through every new path (#2414) =="
while IFS='|' read -r _label _line _want; do
    OUT="$(printf '%s\n' "$_line" | bre)"
    if [ "$OUT" = "$_want" ]; then
        it_pass "$_label survives readable"
    else
        it_fail "$_label survives readable" "want: $_want got: $OUT"
    fi
done <<'ROWS'
indented survivor|    STRATUM_PORT=3333|    STRATUM_PORT=3333
export survivor|export STRATUM_PORT=3333|export STRATUM_PORT=3333
commented survivor|# STRATUM_PORT=3334|# STRATUM_PORT=3334
survivor with a trailing note|STRATUM_PORT=3333   # note|STRATUM_PORT=3333 # [redacted]
indented export survivor with a note|	export TARI_MODE=full # note|	export TARI_MODE=full # [redacted]
quoted survivor with spaces|P2POOL_FLAGS="--mini --socks5 172.28.0.2:9050"|P2POOL_FLAGS="--mini --socks5 172.28.0.2:9050"
quoted survivor with an escaped quote and a hash|P2POOL_FLAGS="a \" # b" # note|P2POOL_FLAGS="a \" # b" # [redacted]
survivor in comment prose|# was STRATUM_PORT=3334 until May|# was STRATUM_PORT=3334 until May
survivor URL in comment prose|# was MONERO_WALLET_RPC_URL=http://127.0.0.1:18082/json_rpc ok|# was MONERO_WALLET_RPC_URL=http://127.0.0.1:18082/json_rpc ok
ROWS

echo "== unit: comment structure and non-secret configuration survive (#2414) =="
FIXTURE='# Monero node
# MONERO_NODE_PASSWORD=OLDSECRETA

MONERO_NODE_PASSWORD=LIVESECRETB
# STRATUM_PORT=3334
    STRATUM_PORT=3333'
WANT='# Monero node
# MONERO_NODE_PASSWORD=[redacted]

MONERO_NODE_PASSWORD=[redacted]
# STRATUM_PORT=3334
    STRATUM_PORT=3333'
OUT="$(printf '%s\n' "$FIXTURE" | bre)"
if [ "$OUT" = "$WANT" ]; then
    it_pass "a hand-edited .env keeps its markers, prose, blanks and survivors line for line"
else
    it_fail "a hand-edited .env keeps its markers, prose, blanks and survivors line for line" \
        "got: $OUT"
fi

# --- FULL POPULATION SWEEP ----------------------------------------------------------------------
# Hand-classified against the rendered population, measured 127 keys at the time of this change.
# A key in neither list fails below BY NAME.
MUST_REDACT="MONERO_NODE_USERNAME MONERO_NODE_PASSWORD WALLET_RPC_PASSWORD TARI_WALLET_PASSWORD
PROXY_STRATUM_PASSWORD PROXY_AUTH_TOKEN XMRIG_API_TOKEN TELEGRAM_BOT_TOKEN NTFY_TOKEN
DASHBOARD_AUTH_USER DASHBOARD_AUTH_HASH_B64 DASHBOARD_AUTH_PW_FP TARI_SPEND_PUBLIC_KEY
MONERO_WALLET_ADDRESS MONERO_VIEW_KEY TARI_WALLET_ADDRESS TARI_VIEW_KEY XVB_DONOR_ID
MONERO_ONION_ADDRESS TARI_ONION_ADDRESS P2POOL_ONION_ADDRESS DASHBOARD_ONION_ADDRESS
DASHBOARD_ONION_CLIENT_PUBKEY DASHBOARD_ONION_CLIENT_PRIVKEY NTFY_URL NOTIFY_WEBHOOK_URLS
HEALTHCHECKS_PING_URL XVB_STANDBY_SOURCE TELEGRAM_CHAT_ID MONERO_NODE_HOST MONERO_RPC_URL TARI_GRPC_ADDRESS HOST_IP"

MUST_SURVIVE="CADDY_LOG_DIR CLEARNET_STATE_DIR COMPOSE_PROFILES CONTROL_DIR
DASHBOARD_CHECK_UPDATES DASHBOARD_CONTROL_ENABLED DASHBOARD_DATA_DIR DASHBOARD_EXPOSE_PUBLIC_IP
DASHBOARD_FAIL_CLOSED DASHBOARD_ONION_CLIENT_AUTH DASHBOARD_ONION_ENABLED DASHBOARD_SECURE
DASHBOARD_TZ DEPLOYMENT_COMPLETED HASHRATE_DROP_MINUTES HASHRATE_DROP_THRESHOLD_PCT HOST_PORT
MONERO_CLEARNET_SYNC MONERO_DATA_DIR MONERO_MEM_LIMIT MONERO_OUT_PEERS MONERO_PREP_THREADS
MONERO_PRUNE MONERO_RPC_BIND MONERO_RPC_PORT MONERO_WALLET_RPC_URL MONERO_ZMQ_BIND MONERO_ZMQ_PORT
NETWORK_PREFIX NETWORK_SUBNET NOTIFY_TOR P2POOL_CLEARNET P2POOL_DATA_DIR P2POOL_FLAGS P2POOL_PORT
P2POOL_URL PAYOUT_CONFIRM_ENABLED PAYOUT_SCAN_HEIGHT PITHEAD_TLS_DIR PROXY_API_PORT
PROXY_DONATE_LEVEL PROXY_STRATUM_TLS PROXY_TLS_DIR STRATUM_BIND STRATUM_PORT TARI_CLEARNET_SYNC
TARI_DATA_DIR TARI_GRPC_BIND TARI_MEM_LIMIT TARI_MODE TARI_PAYOUT_CONFIRM_ENABLED TARI_REQUIRED
TARI_WALLET_BIRTHDAY TARI_WALLET_GRPC_ADDRESS TARI_WALLET_SECRET_FILE TELEGRAM_COMMANDS_ENABLED
TELEGRAM_DAILY_SUMMARY_TIME TELEGRAM_ENABLED TELEGRAM_EVENT_BLOCK_FOUND
TELEGRAM_EVENT_CLEARNET_EXPOSED TELEGRAM_EVENT_CONTAINER_UNHEALTHY TELEGRAM_EVENT_DAILY_SUMMARY
TELEGRAM_EVENT_DB_RESET TELEGRAM_EVENT_DB_UNHEALTHY TELEGRAM_EVENT_DISK_SPACE
TELEGRAM_EVENT_HASHRATE_LOSS TELEGRAM_EVENT_HASHRATE_LOW TELEGRAM_EVENT_HIGH_REJECT_RATE
TELEGRAM_EVENT_HUGEPAGES TELEGRAM_EVENT_LOW_RAM TELEGRAM_EVENT_NEW_RELEASE
TELEGRAM_EVENT_NODE_DOWN TELEGRAM_EVENT_NODE_RECOVERED TELEGRAM_EVENT_PAYOUT_CONFIRMED
TELEGRAM_EVENT_PAYOUT_FOUND TELEGRAM_EVENT_RAFFLE_WIN TELEGRAM_EVENT_STACK_ONLINE
TELEGRAM_EVENT_SYNC_FINISHED TELEGRAM_EVENT_WALLET_CHANGED TELEGRAM_EVENT_WORKER_JOINED
TELEGRAM_EVENT_WORKER_LEFT TELEGRAM_EVENT_WORKER_OFFLINE TELEGRAM_EVENT_WORKER_RECOVERED
TELEGRAM_EVENT_XVB_NO_SHARE TELEGRAM_EVENT_XVB_REGISTRATION TOR_AUTO_HEAL TOR_DATA_DIR
TOR_EGRESS_FIREWALL WALLET_RPC_USERNAME XMRIG_API_AUTH XMRIG_API_PORT XVB_DONATION_LEVEL
XVB_ENABLED XVB_POOL_URL XVB_TOR_ENABLED"

# Word-splitting, not a `case` glob: the lists above wrap across lines, and a space-delimited
# haystack silently misses every entry sitting next to a newline (#1611's sibling defect).
in_list() { # <key> <list>
    local needle="$1" item
    for item in $2; do [ "$item" = "$needle" ] && return 0; done
    return 1
}

echo "== redact: every rendered .env key is classified and the classification holds (#1631) =="

SCREENED="$(
    python3 - "$RENDER" <<'PY'
import re, sys

src = open(sys.argv[1], encoding="utf-8").read().split("\n")
try:
    start = next(i for i, l in enumerate(src) if l.strip() == 'cat <<EOF >"$target"')
    end = next(i for i, l in enumerate(src) if i > start and l == "EOF")
except StopIteration:
    print("!!could not locate render_env's .env heredoc in 33-render-env.sh")
    raise SystemExit(0)

keys = sorted({m.group(1) for l in src[start + 1:end] if (m := re.match(r"^([A-Z][A-Z0-9_]*)=", l))})
if len(keys) < 100:
    print(f"!!the .env population read as only {len(keys)} keys — the heredoc bounds moved")
    raise SystemExit(0)

for k in keys:
    print(k)
PY
)"
POP_BAD="$(printf '%s\n' "$SCREENED" | sed -n 's/^!!//p')"
SCREENED="$(printf '%s\n' "$SCREENED" | grep -v '^!!')"
if [ -n "$POP_BAD" ]; then
    it_fail "the .env population is derived from render_env" "$POP_BAD"
elif [ -z "$SCREENED" ]; then
    it_fail "the .env population is derived from render_env" "screen returned nothing"
else
    it_pass "the .env population is derived from render_env"
fi

for key in $SCREENED; do
    if ! in_list "$key" "$MUST_REDACT $MUST_SURVIVE"; then
        it_fail ".env key $key is classified" \
            "new render_env key — add it to MUST_REDACT or MUST_SURVIVE with a reason"
        continue
    fi
    OUT="$(printf '%s=SENTINELVALUE\n' "$key" | bre)"
    if in_list "$key" "$MUST_REDACT"; then
        case "$OUT" in
        *SENTINELVALUE*) it_fail "$key is redacted" "raw value survived: $OUT" ;;
        *) it_pass "$key is redacted" ;;
        esac
    else
        case "$OUT" in
        *SENTINELVALUE*) it_pass "$key survives, as a bundle needs it to" ;;
        *) it_fail "$key survives, as a bundle needs it to" "over-redacted: $OUT" ;;
        esac
    fi
done

echo "selftest-bundle-redact-env: $IT_PASS passed, $IT_FAIL failed"
[ "$IT_FAIL" -eq 0 ] || exit 1
