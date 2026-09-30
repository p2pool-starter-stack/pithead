# shellcheck shell=bash
: "${STACK_SUITE:?is unset: this file is a tests/stack/run.sh fragment, not a script — run tests/stack/run.sh}"
# Monero chain health (#2499): the container healthcheck, doctor and status read the same peers and
# tip fields the dashboard does. Reuses test-doctor.sh's DRBIN stubs (curl prints CURL_BODY).

echo "== unit: monerod healthcheck fails a peerless node past the bound (#2499, #2921) =="
# A stub curl answers the liveness call; a stub helper stands in for monerod-peers.sh (which reads the
# admin listener), so the counts the healthcheck acts on never come from the restricted get_info.
mon_hc() { # <out-peers|unavailable|down> <bound-sec> <stamp-age-sec|none> -> "rc=N stamp=... line=..."
    local d rc line
    mk_tmpdir d
    if [ "$1" = down ]; then
        printf '#!/bin/sh\nexit 22\n' >"$d/curl"
    else
        # The restricted listener's get_info always says 0 here: a healthcheck reading it would go red.
        printf '#!/bin/sh\necho %s\n' "'{\"status\":\"OK\",\"outgoing_connections_count\":0,\"restricted\":true}'" >"$d/curl"
    fi
    if [ "$1" = unavailable ] || [ "$1" = down ]; then
        printf '#!/bin/sh\nexit 3\n' >"$d/peers"
    else
        printf '#!/bin/sh\necho %s\n' "'{\"outgoing\":$1,\"incoming\":2,\"white\":5,\"grey\":6}'" >"$d/peers"
    fi
    chmod +x "$d/curl" "$d/peers"
    [ "$3" = none ] || echo $(($(date +%s) - $3)) >"$d/stamp"
    line="$(PATH="$d:$PATH" MONERO_HEALTH_STAMP="$d/stamp" MONERO_HEALTH_PEERLESS_SEC="$2" MONERO_PEERS_HELPER="$d/peers" \
        sh "$ROOT/build/monero/healthcheck.sh" 2>/dev/null)"
    rc=$?
    line="$(printf '%s' "$line" | head -n1)"
    echo "rc=$rc stamp=$([ -e "$d/stamp" ] && echo kept || echo cleared) line=$line"
    rm -rf "$d"
}
assert_eq "healthcheck: peers present -> healthy, stamp cleared, real counts published" "$(mon_hc 8 600 30)" \
    'rc=0 stamp=cleared line=pithead-monero-peers {"outgoing":8,"incoming":2,"white":5,"grey":6}'
assert_contains "healthcheck: first real zero -> healthy, stamp started" "$(mon_hc 0 600 none)" "rc=0 stamp=kept"
assert_contains "healthcheck: zero peers under the bound -> healthy" "$(mon_hc 0 600 300)" "rc=0 stamp=kept"
assert_contains "healthcheck: zero peers past the bound -> unhealthy" "$(mon_hc 0 600 700)" "rc=1 stamp=kept"
assert_eq "healthcheck: RPC not answering -> unhealthy, and the stale stamp is dropped" "$(mon_hc down 600 700 | cut -d' ' -f1-2)" "rc=1 stamp=cleared"
assert_eq "healthcheck: restricted zeros are never read: helper unavailable -> unhealthy, no stamp, says unavailable" "$(mon_hc unavailable 600 700)" \
    "rc=1 stamp=cleared line=pithead-monero-peers unavailable"

echo "== unit: the rendered RPC split (#2921) =="
TPL="$ROOT/build/monero/bitmonero.conf.template"
tpl_has() { grep -cE "$1" "$TPL"; }
assert_eq "template: the admin RPC binds the container loopback only" "$(tpl_has '^rpc-bind-ip=127\.0\.0\.1$')" "1"
assert_eq "template: the admin RPC has its own unpublished port" "$(tpl_has '^rpc-bind-port=18085$')" "1"
assert_eq "template: the network listener is the restricted one, on the published port" "$(tpl_has '^rpc-restricted-bind-ip=0\.0\.0\.0$')$(tpl_has '^rpc-restricted-bind-port=18081$')" "11"
assert_eq "template: no global restricted-rpc (it would restrict the admin listener too)" "$(tpl_has '^restricted-rpc')" "0"
assert_eq "template: IPv6 stays off" "$(tpl_has '^rpc-use-ipv6=(1|true)')" "0"
assert_eq "template: the login guards both listeners" "$(tpl_has '^rpc-login=')" "1"
assert_eq "template: public RPC selection is enabled for the restricted listener" "$(tpl_has '^public-node=1$')" "1"
assert_eq "no compose publish or quadlet publish names the admin port" "$(grep -rc 18085 "$ROOT/docker-compose.yml" "$ROOT"/os/quadlet/*/monerod.container | awk -F: '{s+=$2} END {print s+0}')" "0"

echo "== unit: monerod-peers.sh reads only a non-restricted body (#2921) =="
mon_peers() { # <get_info body|down>
    local d out rc
    mk_tmpdir d
    if [ "$1" = down ]; then printf '#!/bin/sh\nexit 7\n' >"$d/curl"; else printf '#!/bin/sh\ncat <<'"'"'EOF'"'"'\n%s\nEOF\n' "$1" >"$d/curl"; fi
    chmod +x "$d/curl"
    out="$(PATH="$d:$PATH" MONERO_NODE_USERNAME=u MONERO_NODE_PASSWORD=s3cr3tpw sh "$ROOT/build/monero/peers.sh" 2>&1)"
    rc=$?
    echo "rc=$rc out=$out"
    rm -rf "$d"
}
REAL='{
  "outgoing_connections_count": 0,
  "incoming_connections_count": 0,
  "white_peerlist_size": 0,
  "grey_peerlist_size": 0,
  "restricted": false,
  "status": "OK"
}'
assert_eq "peers.sh: an unrestricted body with real zeros is a reading of zero" "$(mon_peers "$REAL")" \
    'rc=0 out={"outgoing":0,"incoming":0,"white":0,"grey":0}'
assert_eq "peers.sh: a restricted body (its zeros are redacted) is refused" "$(mon_peers "$(printf '%s' "$REAL" | sed 's/"restricted": false/"restricted": true/')")" "rc=3 out="
assert_eq "peers.sh: a body that does not say restricted is refused" "$(mon_peers "$(printf '%s' "$REAL" | sed '/restricted/d')")" "rc=3 out="
assert_eq "peers.sh: a missing count is refused" "$(mon_peers "$(printf '%s' "$REAL" | sed '/white_peerlist/d')")" "rc=3 out="
assert_eq "peers.sh: malformed JSON is refused" "$(mon_peers '{"restricted":false,"outgoing_connections_count":7')" "rc=3 out="
assert_eq "peers.sh: a string count is refused" "$(mon_peers "$(printf '%s' "$REAL" | sed 's/"outgoing_connections_count": 0/"outgoing_connections_count": "0"/')")" "rc=3 out="
assert_eq "peers.sh: no answer is refused" "$(mon_peers down)" "rc=1 out="
assert_not_contains "peers.sh: never prints the login" "$(mon_peers "$REAL")" "s3cr3tpw"

echo "== unit: doctor + status Monero chain verdict (#2499) =="
mon_state() { # <level> <reasons-json-array> <advice>
    printf '{"monero":{"health":{"level":"%s","reasons":%s,"advice":"%s"}}}' "$1" "$2" "$3"
}
RED="$(mon_state red '["0 outgoing peers for 11 min"]' "restart monerod")"
out="$(CURL_BODY="$RED" PATH="$DRBIN:$PATH" run_sourced "$SANDBOX" check_monero_chain 2>&1)"
assert_contains "monero chain: red -> doctor FAIL names the verdict" "$out" "NOT following the chain"
assert_contains "monero chain: red -> doctor carries the numbers and next step" "$out" "0 outgoing peers for 11 min — next: restart monerod"
mon_chain_fail_count() { DR_FAIL=0 && check_monero_chain >/dev/null 2>&1 && echo "$DR_FAIL"; }
assert_eq "monero chain: red counts as a doctor failure" \
    "$(CURL_BODY="$RED" PATH="$DRBIN:$PATH" run_sourced "$SANDBOX" mon_chain_fail_count)" "1"
out="$(CURL_BODY="$(mon_state green '[]' '')" PATH="$DRBIN:$PATH" run_sourced "$SANDBOX" check_monero_chain 2>&1)"
assert_contains "monero chain: green -> OK" "$out" "at the tip with peers"
out="$(CURL_BODY='{"monero":{"health":{"level":"unknown","reasons":[],"advice":""}}}' PATH="$DRBIN:$PATH" run_sourced "$SANDBOX" check_monero_chain 2>&1)"
assert_eq "monero chain: no verdict (remote node) -> silent" "$out" ""
out="$(CURL_RC=7 PATH="$DRBIN:$PATH" run_sourced "$SANDBOX" check_monero_chain 2>&1)"
assert_eq "monero chain: dashboard not answering -> silent" "$out" ""
out="$(CURL_BODY="$RED" PATH="$DRBIN:$PATH" run_sourced "$SANDBOX" monero_chain_status_line 2>&1)"
assert_contains "monero chain: status prints the red line" "$out" "monero chain  NOT following the chain: 0 outgoing peers for 11 min"
out="$(CURL_BODY="$(mon_state green '[]' '')" PATH="$DRBIN:$PATH" run_sourced "$SANDBOX" monero_chain_status_line 2>&1)"
assert_contains "monero chain: status prints the green line" "$out" "monero chain  at the tip, with peers"

echo "== unit: doctor prints peers next to the sync flag (#2499, #2921) =="
# The counts come from the in-container helper (PEERS_JSON), never from get_info, whose restricted
# body says 0 for them: every body below carries zeros, and only the helper decides.
RESTRICTED_INFO='{"status":"OK","synchronized":true,"target_height":0,"restricted":true,"outgoing_connections_count":0,"incoming_connections_count":0}'
out="$(RUNNING_CONTAINERS="monerod" PEERS_JSON='{"outgoing":8,"incoming":3,"white":1,"grey":1}' CURL_BODY="$RESTRICTED_INFO" PATH="$DRBIN:$PATH" run_sourced "$SANDBOX" check_monerod_synchronized 2>&1)"
assert_contains "monerod peers: the helper's counts are shown, not the restricted zeros" "$out" "monerod peers: 8 out / 3 in"
out="$(RUNNING_CONTAINERS="monerod" PEERS_JSON='{"outgoing":0,"incoming":0,"white":0,"grey":0}' CURL_BODY="$RESTRICTED_INFO" PATH="$DRBIN:$PATH" run_sourced "$SANDBOX" check_monerod_synchronized 2>&1)"
assert_contains "monerod peers: a real zero from the helper -> WARN with the count" "$out" "monerod peers: 0 out / 0 in"
assert_contains "monerod peers: the zero-peer line is a WARN" "$out" "WARN"
out="$(PITHEAD_APPLIANCE=1 RUNNING_CONTAINERS="monerod" PEERS_JSON='{"outgoing":0,"incoming":0,"white":0,"grey":0}' CURL_BODY="$RESTRICTED_INFO" PATH="$DRBIN:$PATH" run_sourced "$SANDBOX" check_monerod_synchronized 2>&1)"
assert_contains "monerod peers: appliance warning names its log route" "$out" "check its container logs in the dashboard"
assert_not_contains "monerod peers: appliance warning names no CLI verb" "$out" "./pithead restart"
out="$(RUNNING_CONTAINERS="monerod" PEERS_RC=3 CURL_BODY="$RESTRICTED_INFO" PATH="$DRBIN:$PATH" run_sourced "$SANDBOX" check_monerod_synchronized 2>&1)"
assert_contains "monerod peers: a helper with no reading says so" "$out" "monerod peers: no reading"
assert_not_contains "monerod peers: no reading is never printed as zero peers" "$out" "0 out"
out="$(RUNNING_CONTAINERS="monerod" PEERS_JSON='{"outgoing":"8","incoming":3}' CURL_BODY="$RESTRICTED_INFO" PATH="$DRBIN:$PATH" run_sourced "$SANDBOX" check_monerod_synchronized 2>&1)"
assert_contains "monerod peers: a malformed helper body is no reading" "$out" "monerod peers: no reading"
