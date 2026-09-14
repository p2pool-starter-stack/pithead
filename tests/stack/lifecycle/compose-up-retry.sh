# shellcheck shell=bash
: "${STACK_SUITE:?is unset: this file is a tests/stack/run.sh fragment, not a script — run tests/stack/run.sh}"
# compose_up_checked's bounded retry (#2218): a passenger container mid-transition must delay an
# `up`, never veto it. The dashboard's sync-gate/node-down worker stops and starts p2pool through
# the docker-control proxy (#31/#35) on its own schedule, uncoordinated with the mutation lock the
# CLI holds — so compose can reach p2pool between states and abort the WHOLE up on it, which is
# what failed an approved dashboard apply on the tier-4 provision battery. #1684 had already hit
# the identical race at boot and retried `pithead up` from pithead-boot; the retry now lives in the
# one function every caller shares, so `apply` (the reported path) and `up` are both covered.
# Sourced by tests/stack/test-lifecycle.sh.
#
# Self-contained by construction (the #1330 rule): every sandbox, stub and env file below is built
# here, so this file does not depend on running after any other domain. It reads only lib.sh
# globals ($SANDBOX, $STACK, $ROOT, $VALID_PRIMARY, $VALID_TARI).

CUR="$SANDBOX/compose-up-retry"
CUR_CALLS="$CUR/up-calls"
rm -rf "$CUR"
mkdir -p "$CUR/bin" "$CUR/build/tari" "$CUR/dashboard" \
    "$CUR/data/monero" "$CUR/data/tari" "$CUR/data/p2pool/stats" "$CUR/data/tor" "$CUR/data/dashboard"
: >"$CUR/dashboard/Dockerfile" # source-checkout marker → pithead builds, so the up is --pull never (#44)
cp "$STACK" "$CUR/pithead"
cp "$ROOT/build/tari/config.toml.template" "$CUR/build/tari/"
printf '#!/usr/bin/env bash\nexit 0\n' >"$CUR/bin/sudo"
chmod +x "$CUR/bin/sudo"
cat >"$CUR/.env" <<EOF
MONERO_ONION_ADDRESS=mona.onion
TARI_ONION_ADDRESS=taria.onion
P2POOL_ONION_ADDRESS=p2pa.onion
PROXY_AUTH_TOKEN=ORIGINALTOKEN
HOST_IP=box.lan
DEPLOYMENT_COMPLETED=true
COMPOSE_PROFILES=local_node
MONERO_DATA_DIR=$CUR/data/monero
TARI_DATA_DIR=$CUR/data/tari
P2POOL_DATA_DIR=$CUR/data/p2pool
DASHBOARD_DATA_DIR=$CUR/data/dashboard
TOR_DATA_DIR=$CUR/data/tor
EOF
cur_config() { # <p2pool-pool> — a distinct pool value is how each case forces a real apply delta
    printf '{ "monero": {"mode":"local","wallet_address":"%s","node_username":"u","node_password":"p"}, "tari":{"wallet_address":"%s"}, "p2pool":{"pool":"%s"}, "dashboard":{"secure":false,"host":"box.lan"} }\n' \
        "$VALID_PRIMARY" "$VALID_TARI" "$1" >"$CUR/config.json"
}
# A docker stub whose ONLY scripted behaviour is the `compose up`: it counts every call and fails
# the first $1 of them, standing in for the window where p2pool is neither up nor down. Everything
# else a lifecycle verb shells out to succeeds silently, as in the sibling black-boxes.
cur_stub() { # <failing-tries>
    cat >"$CUR/bin/docker" <<EOF
#!/usr/bin/env bash
case "\$*" in
"compose up --pull never -d"*)
    n=\$(cat "$CUR_CALLS" 2>/dev/null || echo 0)
    echo "\$((n + 1))" >"$CUR_CALLS"
    [ "\$((n + 1))" -gt "$1" ]
    exit \$?
    ;;
"exec tor cat "*) echo "mona.onion" ;;
esac
exit 0
EOF
    chmod +x "$CUR/bin/docker"
    : >"$CUR_CALLS"
}
# No run helper on purpose: a function cannot hand its exit status back through `$( )`, which runs
# it in a subshell, so every call site below captures `$?` itself, as the sibling black-boxes do.
# The env prefix is written out literally for the same class of reason — bash decides what is an
# assignment prefix before expansion, so a "VAR=value" word produced by one is a command name.

echo "== black-box: apply rides out a transient 'compose up' failure in the SAME call (#2218) =="
# The reported path: an approved disruptive setting is submitted, the control runner commits it and
# calls `apply -y`. One passenger transition used to fail the apply outright and record it failed —
# leaving the incomplete marker for a retry nobody was there to run.
cur_config mini
cur_stub 1
out="$(cd "$CUR" && PITHEAD_COMPOSE_UP_PAUSE=0 PATH="$CUR/bin:$PATH" ./pithead apply -y 2>&1)"
assert_rc "apply recovers inside one call when the first compose up fails" "$?" "0"
assert_contains "and says it is retrying, naming the try" "$out" "try 1 of 3"
assert_eq "having called compose up exactly twice" "$(cat "$CUR_CALLS")" "2"
assert_eq "no incomplete marker survives a same-call recovery" \
    "$([ -f "$CUR/.env.apply-incomplete" ] && echo present || echo absent)" "absent"

echo "== black-box: the retry is bounded — a real failure still fails apply (#2218) =="
# The bound is the whole point: a retry that never gives up would hide a genuine compose fault
# (a port already bound, a failed dependency gate) behind an apply that hangs instead of reporting.
cur_config observer
cur_stub 99
out="$(cd "$CUR" && PITHEAD_COMPOSE_UP_PAUSE=0 PATH="$CUR/bin:$PATH" ./pithead apply -y 2>&1)"
assert_rc "apply still fails once every try is spent" "$?" "1"
assert_eq "after exactly 3 tries, never more" "$(cat "$CUR_CALLS")" "3"
assert_contains "and prints the unchanged #125 recovery guidance" "$out" "were NOT recreated"
assert_eq "leaving the incomplete marker for the next apply (#125)" \
    "$([ -f "$CUR/.env.apply-incomplete" ] && echo present || echo absent)" "present"
rm -f "$CUR/.env.apply-incomplete"

echo "== black-box: 'up' gets the same retry, because the fix is in the shared function (#2218) =="
# #1684 retried at ONE call site and left every other caller exposed; the same passenger races a
# plain `up`. Proving `up` here is what makes the placement — compose_up_checked, not the apply
# verb — a claim the suite checks rather than a comment.
cur_stub 1
out="$(cd "$CUR" && PITHEAD_COMPOSE_UP_PAUSE=0 PATH="$CUR/bin:$PATH" ./pithead up 2>&1)"
assert_rc "up recovers inside one call when the first compose up fails" "$?" "0"
assert_contains "and announces the retry the same way" "$out" "try 1 of 3"
assert_eq "having called compose up exactly twice" "$(cat "$CUR_CALLS")" "2"

echo "== unit: the try count is the knob PITHEAD_COMPOSE_UP_TRIES sets (#2218) =="
# A box that wants longer odds (or a test that wants none) sets the count; 1 is "no retry at all",
# the pre-#2218 behaviour, and is what keeps this bound honest rather than hard-coded.
cur_stub 99
out="$(cd "$CUR" && PITHEAD_COMPOSE_UP_TRIES=1 PITHEAD_COMPOSE_UP_PAUSE=0 PATH="$CUR/bin:$PATH" ./pithead up 2>&1)"
assert_rc "up with the count at 1 fails on the first try" "$?" "1"
assert_eq "and calls compose up exactly once" "$(cat "$CUR_CALLS")" "1"
assert_not_contains "announcing no retry it did not make" "$out" "retrying in"
# And a count that yields no iterations at all (0, or anything `seq` refuses) must still come back
# as an honest failure. The CLI runs under `set -Eeuo pipefail`, so an rc left unset by a loop that
# never ran aborts the verb on `unbound variable` — a shell fault where a verdict belongs.
cur_stub 99
out="$(cd "$CUR" && PITHEAD_COMPOSE_UP_TRIES=0 PITHEAD_COMPOSE_UP_PAUSE=0 PATH="$CUR/bin:$PATH" ./pithead up 2>&1)"
assert_rc "up with a count of 0 fails rather than succeeding by default" "$?" "1"
assert_not_contains "and fails as a verdict, not an unbound-variable abort" "$out" "unbound variable"
assert_eq "having called compose up not at all" "$(cat "$CUR_CALLS")" ""
