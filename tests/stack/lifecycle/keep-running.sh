# shellcheck shell=bash
: "${STACK_SUITE:?is unset: this file is a tests/stack/run.sh fragment, not a script — run tests/stack/run.sh}"
# PITHEAD_KEEP_RUNNING (#2639): the e2e harness's knob for leaving unchanged chain nodes running
# while it deploys a branch from a second checkout of the one pinned project. Every whole-stack
# converge goes through compose_up_checked, so that is where the scope is driven: the kept services
# drop out of the up, the rest are named with --no-deps, and a kept service that is not running is
# refused instead of being left down. Sourced by tests/stack/test-lifecycle.sh.

echo "== unit: PITHEAD_KEEP_RUNNING scopes compose_up_checked (#2639) =="
KR="$SANDBOX/keep-running"
KRBIN="$KR/bin"
mkdir -p "$KRBIN"
printf 'COMPOSE_PROFILES=local_node,local_tari,payout_confirm,tari_payout_confirm\n' >"$KR/.env"
# RUNNING_STUB lists the containers `docker ps` reports running; the service list is the stack's.
cat >"$KRBIN/docker" <<'EOF'
#!/usr/bin/env bash
echo "[docker] $*" >> "${DOCKER_LOG:-/dev/null}"
case "$*" in
"compose config --services") printf 'tor\nmonerod\nwallet-rpc\ntari\ntari-wallet\np2pool\ndashboard\n' ;;
"ps -q --filter name=^"*)
    n="${4#name=^}"
    n="${n%\$}"
    case " ${RUNNING_STUB:-} " in *" $n "*) echo "cid-$n" ;; esac
    ;;
esac
exit 0
EOF
chmod +x "$KRBIN/docker"
KRLOG="$KR/docker.log"

kr_up() { # <keep> <running> <compose_up_checked args...> -> rc; the up line lands in $KRLOG
    local keep="$1" running="$2"
    shift 2
    : >"$KRLOG"
    DOCKER_LOG="$KRLOG" RUNNING_STUB="$running" PITHEAD_KEEP_RUNNING="$keep" PATH="$KRBIN:$PATH" \
        run_sourced "$KR" compose_up_checked "$@" >"$KR/out" 2>&1
}
kr_line() { grep 'compose up' "$KRLOG" | tail -1; }
kr_names() { kr_line | tr ' ' '\n'; } # one word per line, so 'tari' never matches 'tari-wallet'

kr_up "monerod tari" "monerod tari" -d
assert_rc "a scoped up succeeds when every kept service is running" "$?" "0"
assert_contains "the rest of the stack is named with --no-deps" "$(kr_line)" "-d --no-deps"
assert_eq "monerod is left out of the up" "$(kr_names | grep -cx monerod)" "0"
assert_eq "tari is left out of the up" "$(kr_names | grep -cx tari)" "0"
assert_eq "every other service is in the up" \
    "$(kr_names | grep -xE 'tor|wallet-rpc|tari-wallet|p2pool|dashboard' | tr '\n' ' ')" "tor wallet-rpc tari-wallet p2pool dashboard "
assert_contains "the scope is announced" "$(cat "$KR/out")" "Keeping monerod tari running"

kr_up "monerod" "monerod" -d --build --remove-orphans
assert_contains "the caller's own flags survive the scoping" "$(kr_line)" "-d --build --no-deps"
# Older Compose v2 counts services left out of a scoped up as orphans, so the flag cannot ride along.
assert_eq "--remove-orphans is dropped from a scoped up" "$(kr_line | grep -c -- --remove-orphans)" "0"
assert_eq "tari stays in the up when only monerod is kept" "$(kr_names | grep -cx tari)" "1"

# An explicit service list (reset-dashboard, the migration hold) is scoped too, never widened.
kr_up "monerod" "monerod" -d dashboard monerod
assert_eq "an explicit service list loses only the kept service" \
    "$(kr_line | sed 's/.* --no-deps//')" " dashboard"

# Every named service kept: no up at all, never an up with no service list (the whole stack).
kr_up "monerod tari" "monerod tari" -d monerod tari
assert_rc "an all-kept service list succeeds" "$?" "0"
assert_eq "an all-kept service list runs no compose up" "$(kr_line)" ""

# The refusal: a kept service that is not running would stay down with nothing to report it.
kr_up "monerod tari" "monerod" -d
assert_rc "a kept service that is not running is refused" "$?" "1"
assert_eq "the refusal runs no compose up" "$(kr_line)" ""
assert_contains "the refusal names the service" "$(cat "$KR/out")" "'tari', which is not running"

kr_up "" "" -d
assert_eq "without the knob the up names no service subset" "$(kr_line | grep -c -- '--no-deps')" "0"
assert_eq "without the knob the up is the whole stack" "$(kr_names | grep -cx p2pool)" "0"
