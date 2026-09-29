# shellcheck shell=bash
: "${STACK_SUITE:?is unset: this file is a tests/stack/run.sh fragment, not a script — run tests/stack/run.sh}"
# Monero chain health (#2499): the container healthcheck, doctor and status read the same peers and
# tip fields the dashboard does. Reuses test-doctor.sh's DRBIN stubs (curl prints CURL_BODY).

echo "== unit: monerod healthcheck fails a peerless node past the bound (#2499) =="
# A stub curl on PATH answers get_info with a chosen outgoing count; the stamp file is sandboxed.
mon_hc() { # <out-peers|none> <bound-sec> <stamp-age-sec|none> -> "rc=N"
    local d rc body
    mk_tmpdir d
    if [ "$1" = none ]; then body='{"status":"OK","height":10}'; else
        body="$(printf '{\n  "outgoing_connections_count": %s,\n  "status": "OK"\n}' "$1")"
    fi
    printf '#!/bin/sh\ncat <<'"'"'EOF'"'"'\n%s\nEOF\n' "$body" >"$d/curl"
    chmod +x "$d/curl"
    [ "$3" = none ] || echo $(($(date +%s) - $3)) >"$d/stamp"
    PATH="$d:$PATH" MONERO_HEALTH_STAMP="$d/stamp" MONERO_HEALTH_PEERLESS_SEC="$2" \
        sh "$ROOT/build/monero/healthcheck.sh" >/dev/null 2>&1
    rc=$?
    echo "rc=$rc stamp=$([ -e "$d/stamp" ] && echo kept || echo cleared)"
    rm -rf "$d"
}
assert_eq "healthcheck: peers present -> healthy, stamp cleared" "$(mon_hc 8 600 30)" "rc=0 stamp=cleared"
assert_eq "healthcheck: first zero reading -> healthy, stamp started" "$(mon_hc 0 600 none)" "rc=0 stamp=kept"
assert_eq "healthcheck: zero peers under the bound -> healthy" "$(mon_hc 0 600 300)" "rc=0 stamp=kept"
assert_eq "healthcheck: zero peers past the bound -> unhealthy" "$(mon_hc 0 600 700)" "rc=1 stamp=kept"
assert_eq "healthcheck: no peer count in the body is never a failure" "$(mon_hc none 600 700)" "rc=0 stamp=cleared"

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

echo "== unit: doctor prints peers next to the sync flag (#2499) =="
out="$(RUNNING_CONTAINERS="monerod" CURL_BODY='{"status":"OK","synchronized":true,"target_height":0,"outgoing_connections_count":8,"incoming_connections_count":3}' PATH="$DRBIN:$PATH" run_sourced "$SANDBOX" check_monerod_synchronized 2>&1)"
assert_contains "monerod peers: peers shown" "$out" "monerod peers: 8 out / 3 in"
out="$(RUNNING_CONTAINERS="monerod" CURL_BODY='{"status":"OK","synchronized":true,"target_height":0,"outgoing_connections_count":0,"incoming_connections_count":0}' PATH="$DRBIN:$PATH" run_sourced "$SANDBOX" check_monerod_synchronized 2>&1)"
assert_contains "monerod peers: synchronized but 0 out -> WARN with the count" "$out" "monerod peers: 0 out / 0 in"
assert_contains "monerod peers: the zero-peer line is a WARN" "$out" "WARN"
