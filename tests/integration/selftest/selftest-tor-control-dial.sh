#!/usr/bin/env bash
#
# Self-test for the retried "clearnet THROUGH Tor" control dial (lib/tor-control-dial.sh, #2619).
# It runs the exact command the e2e harness and the appliance battery send to the box, with the
# container engine and curl replaced by PATH stubs. It pins three things: a dial retries up to
# TOR_CONTROL_DIAL_ATTEMPTS times, each attempt carries its own SOCKS username (so Tor puts it
# on a fresh circuit), and the first success stops the loop. A single-shot dial fails the
# first case. A retry that reuses one username fails the second.
#
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=tests/integration/lib.sh
source "$HERE/../lib.sh"
# shellcheck source=tests/integration/lib/tor-control-dial.sh
source "$HERE/../lib/tor-control-dial.sh"

STUB="$(mktemp -d)"
trap 'rm -rf "$STUB"' EXIT
# The engine stub drops `exec monerod` and runs the rest (`sh -c '<loop>'`) here.
for engine in docker podman; do
    printf '#!/bin/sh\nshift 2\nexec "$@"\n' >"$STUB/$engine"
done
# curl records its argv, one line per attempt, and succeeds on attempt $CURL_OK_ON (0 = never).
cat >"$STUB/curl" <<'EOF'
#!/bin/sh
echo "$*" >>"$CURL_LOG"
n=$(wc -l <"$CURL_LOG")
[ "$n" -eq "${CURL_OK_ON:-0}" ]
EOF
chmod +x "$STUB"/*
export CURL_LOG="$STUB/curl.log"

dial() { # <engine> <ok-on> -> rc of the real command
    : >"$CURL_LOG"
    CURL_OK_ON="$2" PATH="$STUB:$PATH" bash -c "$(tor_control_dial_cmd "$1" 172.28.0.25:9050)"
}

echo "== every attempt fails: the dial tries 3 times on 3 circuits, then fails =="
dial docker 0
assert_eq "all attempts failed -> non-zero" "$?" "1"
assert_eq "three attempts" "$(wc -l <"$CURL_LOG" | tr -d ' ')" "3"
assert_eq "three distinct SOCKS usernames (a fresh circuit each)" \
    "$(grep -o -- '--proxy-user [^ ]*' "$CURL_LOG" | sort -u | wc -l | tr -d ' ')" "3"
assert_eq "every attempt goes through the given SOCKS" \
    "$(grep -c -- '--socks5-hostname 172.28.0.25:9050 http://1.1.1.1/' "$CURL_LOG")" "3"
assert_eq "every attempt allows 45 s" "$(grep -c -- '-m 45 ' "$CURL_LOG")" "3"
assert_contains "failure text names the attempts" "$(tor_control_dial_attempts_text)" "3 attempts of 45s"

echo "== the second attempt connects: the dial passes and stops =="
dial podman 2
assert_eq "second attempt connected -> zero" "$?" "0"
assert_eq "no attempt after the success" "$(wc -l <"$CURL_LOG" | tr -d ' ')" "2"

echo "== the e2e runner loads the helper before run-state.sh, which calls it =="
# selftest-run-modules.sh pins only lib/run-*.sh, so it cannot see this file go missing.
assert_eq "run.sh sources tor-control-dial.sh, then run-state.sh" \
    "$(grep -oE '^source "\$HERE/lib/(tor-control-dial|run-state)\.sh"' "$HERE/../run.sh" | tr '\n' ' ')" \
    'source "$HERE/lib/tor-control-dial.sh" source "$HERE/lib/run-state.sh" '

echo "== the appliance battery dials through the same helper =="
assert_contains "podman command targets monerod" "$(tor_control_dial_cmd podman 172.28.0.25:9050)" "podman exec monerod sh -c"
(
    # shellcheck source=tests/os/appliance-egress-leg.sh
    . "$HERE/../../os/appliance-egress-leg.sh"
    declare -F tor_control_dial_cmd >/dev/null
)
assert_eq "appliance-egress-leg.sh loads the helper" "$?" "0"

echo "selftest-tor-control-dial: $IT_PASS passed, $IT_FAIL failed"
[ "$IT_FAIL" -eq 0 ]
