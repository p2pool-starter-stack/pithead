#!/usr/bin/env bash
#
# Self-test for the `.env` artifact capture (#1631, ruled on #1630).
#
# THE ROUTE, NOT THE RULE. `bundle_redact_env`'s own classification is
# selftest-bundle-redact-env.sh's job. This file proves `capture_artifacts` actually CALLS it — it
# runs the REAL `capture_artifacts` from lib.sh against a fake box in IT_MODE=local, with the REAL
# built `pithead`, exactly as selftest-capture-config.sh does for config.json.
#
# THE DEFECT THIS REPLACES, AND WHY THESE TWO KEYS. `capture_artifacts` used to pipe `.env`
# through `redact()`, the harness's stream-shape denylist — the same one it still uses for logs
# and status. That vocabulary has no name rule for a routing id or a bare host, so
# `TELEGRAM_CHAT_ID` and `HOST_IP` were captured in the clear under the old route: neither carries
# PASSWORD/TOKEN/SECRET/KEY/WALLET/USER or any of redact()'s other suffixes. The allowlist this
# capture now runs classifies both as REDACT for the `.env` document specifically (an
# authorization/topology decision, not a defect in redact() itself — redact() keeps treating
# TELEGRAM_CHAT_ID as a survivor for logs and status, where a bot's own routing id in debug output
# is not the same disclosure as a bundle handed to a stranger).
#
# Run: tests/integration/selftest/selftest-capture-env.sh
#
set -uo pipefail

HERE="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=tests/integration/lib.sh
source "$HERE/../lib.sh"

REPO="$(cd -P "$HERE/../../.." && pwd -P)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
BOX="$TMP/box"
OUT="$TMP/out"
FAKEBIN="$TMP/bin"
mkdir -p "$BOX" "$OUT" "$FAKEBIN"

# The box runs the REAL program — the point of the fix is that nothing here restates its rule.
ln -s "$REPO/pithead" "$BOX/pithead"

# Sentinels are SHORT on purpose. A value of 90+ alnum characters is reached by redact()'s shape
# rule, which would make the rows below pass off the old stream filter rather than off the
# allowlist this capture now runs instead. HOST_IP holds a sentinel, not a real dotted-quad, so
# the IP shape rule cannot be what is being measured here.
CHAT_SENTINEL="CHATIDSENTINEL"
HOST_SENTINEL="HOSTIPSENTINEL"
cat >"$BOX/.env" <<ENV_EOF
STRATUM_PORT=3333
TELEGRAM_CHAT_ID=$CHAT_SENTINEL
HOST_IP=$HOST_SENTINEL
MONERO_RPC_PORT=18081
ENV_EOF

# capture_artifacts also shells out to docker and the dashboard API; stub them so this file tests
# the .env route and nothing else.
printf '#!/bin/sh\nexit 0\n' >"$FAKEBIN/docker"
printf '#!/bin/sh\nexit 1\n' >"$FAKEBIN/curl"
chmod +x "$FAKEBIN/docker" "$FAKEBIN/curl"

export PATH="$FAKEBIN:$PATH"
export IT_MODE=local
export IT_REMOTE_DIR="$BOX"
export IT_PITHEAD=true

echo "== capture_artifacts: .env is masked by the survivor allowlist, not the stream filter (#1631) =="

# ATTRIBUTION. Before anything else, prove the stream filter ALONE leaves both values standing —
# the gap the ruling is about. Without this row a green "absent" below could be some other rule
# doing the work by coincidence.
RAW_THROUGH_REDACT="$(redact <"$BOX/.env")"
assert_contains "attribution: redact() ALONE leaves the chat id — it has no name rule for a routing id" \
    "$RAW_THROUGH_REDACT" "$CHAT_SENTINEL"
assert_contains "attribution: redact() ALONE leaves the host — it has no name rule for a bare host field" \
    "$RAW_THROUGH_REDACT" "$HOST_SENTINEL"

capture_artifacts "env" "$OUT" >/dev/null 2>&1
ART="$(cat "$OUT/env/env.redacted.txt" 2>/dev/null)"

# ARMING. Every row below is an ABSENCE, and an empty or missing artifact makes all of them pass.
assert_contains "control: the capture produced env-shaped content (absences below are earned)" \
    "$ART" "STRATUM_PORT=3333"
assert_contains "control: a non-secret structural value is NOT masked — the allowlist is selective, not a blanket" \
    "$ART" "MONERO_RPC_PORT=18081"

case "$ART" in
*"$CHAT_SENTINEL"*) it_fail "the chat id is absent from the captured .env" "raw authorization value survived the capture" ;;
*) it_pass "the chat id is absent from the captured .env" ;;
esac
case "$ART" in
*"$HOST_SENTINEL"*) it_fail "the host is absent from the captured .env" "raw topology value survived the capture" ;;
*) it_pass "the host is absent from the captured .env" ;;
esac

echo "selftest-capture-env: $IT_PASS passed, $IT_FAIL failed"
[ "$IT_FAIL" -eq 0 ] || exit 1
