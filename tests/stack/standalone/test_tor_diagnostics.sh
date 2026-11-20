#!/usr/bin/env bash
set -euo pipefail
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)
WORK=$(mktemp -d "${TMPDIR:-${RUNNER_TEMP:-/tmp}}/pithead-tor-diag.XXXXXX")
trap 'rm -rf "$WORK"' EXIT
# shellcheck source=lib/pithead/48b-control-tor-recover.sh
source "$ROOT/lib/pithead/48b-control-tor-recover.sh"
mkdir -p "$WORK/bin" "$WORK/data"
printf '%064d' 0 | xxd -r -p >"$WORK/data/control_auth_cookie"
cat >"$WORK/bin/nc" <<'SH'
#!/bin/sh
cat >"$TOR_CAPTURE"
case "${TOR_NC_MODE:-reply}" in
stall) sleep 30 ;;
refuse) exit 1 ;;
*) cat "$TOR_REPLY" ;;
esac
SH
cat >"$WORK/bin/docker" <<'SH'
#!/bin/sh
case "$1" in
exec) [ "${DOCKER_EXEC:-ok}" = ok ] && exec sh "$TOR_DIAG_SCRIPT" || exit 1 ;;
logs) printf '2026-11-19T12:01:02.5Z Nov 19 12:01:02.000 [notice] Bootstrapped 100%% (done): Done\n' ;;
esac
SH
chmod +x "$WORK/bin/nc" "$WORK/bin/docker"
export PATH="$WORK/bin:$PATH" TOR_DATA_DIR="$WORK/data" TOR_CAPTURE="$WORK/request" TOR_REPLY="$WORK/reply"
export TOR_DIAG_SCRIPT="$ROOT/build/tor/diagnostics.sh"
FP=ABCDEF0123456789ABCDEF0123456789ABCDEF01
ONION=seededonionaddressseededonionaddressseededonionaddress56
cat >"$WORK/reply" <<EOF
250 OK
250-version=0.4.9.17 (git-deadbeef)
250 OK
250-status/bootstrap-phase=WARN BOOTSTRAP PROGRESS=100 TAG=done SUMMARY="Done" HOSTADDR=203.0.113.7:9001 HOSTID=$FP
250 OK
250+circuit-status=
1 BUILT \$$FP~seedednickone,\$$FP~seedednicktwo BUILD_FLAGS=NEED_CAPACITY PURPOSE=GENERAL TIME_CREATED=2026-11-19T12:00:00
2 BUILT \$$FP~seedednickone PURPOSE=GENERAL
3 LAUNCHED BUILD_FLAGS=IS_INTERNAL PURPOSE=HS_SERVICE_HSDIR HS_STATE=HSSI_CONNECTING REND_QUERY=$ONION
4 EXTENDED \$$FP~seedednickone PURPOSE=HS_CLIENT_REND REND_QUERY=$ONION.onion
.
250 OK
250+entry-guards=
\$$FP~seedednickone up
\$$FP=seedednicktwo down
\$$FP never-connected
.
250 OK
250-consensus/valid-after=2026-11-19 12:00:00
250 OK
250-consensus/valid-until=2026-11-19 15:00:00
250 OK
250 closing connection
EOF

raw=$(sh "$TOR_DIAG_SCRIPT")
json=$(tor_diagnostics_snapshot)
echo "== redaction: no guard identity, relay path, onion or address leaves the snapshot =="
for secret in "$FP" seedednickone seedednicktwo "$ONION" 203.0.113.7 HOSTADDR REND_QUERY "0000000000000000"; do
    if grep -qF "$secret" <<<"$raw"; then
        echo "collector output leaked $secret" >&2
        exit 1
    fi
    if grep -qF "$secret" <<<"$json"; then
        echo "host snapshot leaked $secret" >&2
        exit 1
    fi
done

echo "== snapshot fields from a live control port =="
grep -q '^AUTHENTICATE 0\{64\}' "$WORK/request"
for q in version status/bootstrap-phase circuit-status entry-guards consensus/valid-after consensus/valid-until; do
    grep -q "^GETINFO $q" "$WORK/request"
done
[ "$(jq -c '{control, version, bootstrap}' <<<"$json")" = \
    '{"control":"ok","version":"0.4.9.17","bootstrap":{"progress":100,"tag":"done","changed_at":1795089662}}' ]
[ "$(jq -c .circuits <<<"$json")" = \
    '[{"state":"BUILT","purpose":"GENERAL","count":2},{"state":"EXTENDED","purpose":"HS_CLIENT_REND","count":1},{"state":"LAUNCHED","purpose":"HS_SERVICE_HSDIR","count":1}]' ]
[ "$(jq -c .guards <<<"$json")" = '{"down":1,"never-connected":1,"up":1}' ]
[ "$(jq -c '.consensus | {source, valid_after, valid_until}' <<<"$json")" = \
    '{"source":"control","valid_after":1795089600,"valid_until":1795100400}' ]
jq -e '.consensus.age_sec == .taken_at - 1795089600' <<<"$json" >/dev/null

echo "== a stalled control port is unreachable data within the timeout, with the file-time fallback =="
printf 'network-status-version 3 microdesc\nvalid-after 2026-11-19 09:00:00\nfresh-until 2026-11-19 10:00:00\nvalid-until 2026-11-19 12:00:00\n' \
    >"$WORK/data/cached-microdesc-consensus"
start=$SECONDS
json=$(TOR_NC_MODE=stall tor_diagnostics_snapshot)
[ $((SECONDS - start)) -lt 12 ]
[ "$(jq -r .control <<<"$json")" = unreachable ]
[ "$(jq -c '.consensus | {source, valid_after, valid_until}' <<<"$json")" = \
    '{"source":"file","valid_after":1795078800,"valid_until":1795089600}' ]

echo "== a refused control port is unreachable data =="
json=$(TOR_NC_MODE=refuse tor_diagnostics_snapshot)
[ "$(jq -r .control <<<"$json")" = unreachable ]
[ "$(jq -r .consensus.source <<<"$json")" = file ]

echo "== a consensus file without times falls back to its modification age =="
printf 'network-status-version 3 microdesc\n' >"$WORK/data/cached-microdesc-consensus"
touch -d '@'"$(($(date +%s) - 1200))" "$WORK/data/cached-microdesc-consensus"
json=$(TOR_NC_MODE=refuse tor_diagnostics_snapshot)
jq -e '.consensus | .source == "file" and .valid_after == null and .age_sec >= 1200 and .age_sec < 1300' <<<"$json" >/dev/null

echo "== an unreadable cookie and an unreachable container are unreachable data, never a failure =="
mv "$WORK/data/control_auth_cookie" "$WORK/cookie.bak"
[ "$(tor_diagnostics_snapshot | jq -r .control)" = unreachable ]
mv "$WORK/cookie.bak" "$WORK/data/control_auth_cookie"
json=$(DOCKER_EXEC=fail tor_diagnostics_snapshot)
jq -e '.control == "unreachable" and .circuits == [] and .guards == {} and .consensus.source == "none"' <<<"$json" >/dev/null
echo "PASS: Tor diagnostics snapshot"
