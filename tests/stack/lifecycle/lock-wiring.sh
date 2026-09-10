# shellcheck shell=bash
: "${STACK_SUITE:?source via tests/stack/run.sh}"
# WIRING, verb by verb. Everything above proves the lock PRIMITIVE; these prove each verb is
# actually attached to it. Every runtime case above drives stack_down, so six of the eight locked
# verbs could stop acquiring — or stop releasing — with nothing going red.
LKW="$SANDBOX/lockwiring"
mkdir -p "$LKW/bin"
make_stubs "$LKW/bin"
cat >"$LKW/bin/sudo" <<'SUDOEOF'
#!/usr/bin/env bash
# restore's chown to the container uid cannot work unprivileged; everything else runs as the
# test user, so the verb reaches its own window instead of aborting before it.
[ "$1" = "chown" ] && exit 0
exec "$@"
SUDOEOF
chmod +x "$LKW/bin/sudo"
# A provisioned install, rebuildable — every verb driven below WRITES to it, and a used fixture
# stops being a fixture. The hand-written .env is deliberately not what a render produces, so
# `apply` sees a change and takes its committing branch rather than returning early — but that
# holds only on a directory no verb has run in yet. The free half of each pair below re-renders
# this .env, so by the time `apply` is probed on the shared fixture there is nothing left to
# change. That is why the committing branch is driven on its own fixture, here and in
# lock_wiring_balance.
lock_wiring_fixture() { # <dir>
    mkdir -p "$1/data/tor" "$1/data/dashboard"
    cat >"$1/.env" <<'ENVEOF'
MONERO_ONION_ADDRESS=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa.onion
TARI_ONION_ADDRESS=bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb.onion
P2POOL_ONION_ADDRESS=cccccccccccccccccccccccccccccccccccccccccccccccccccccccc.onion
PROXY_AUTH_TOKEN=0123456789abcdef01234567
HOST_IP=box.lan
DEPLOYMENT_COMPLETED=true
COMPOSE_PROFILES=local_node
ENVEOF
    printf '{ "monero": {"mode":"local","wallet_address":"%s","node_username":"u","node_password":"p"}, "tari":{"wallet_address":"%s"}, "p2pool":{"pool":"main"}, "dashboard":{"secure":true,"host":"box.lan"} }\n' "$WALLET" "$VALID_TARI" >"$1/config.json"
    printf 'CADDY-ORIG\n' >"$1/Caddyfile"
    printf 'ONIONKEY-ORIG\n' >"$1/data/tor/hs_ed25519_secret_key"
    printf 'DBDATA-ORIG\n' >"$1/data/dashboard/dashboard.db"
    tar -czf "$1/wiring-archive.tar.gz" -C / "${1#/}/config.json" "${1#/}/.env" "${1#/}/Caddyfile"
}
lock_wiring_fixture "$LKW"
LKWHELD="$LKW/held.lock"
LKWFREE="$LKW/free.lock"
# Which directory a pair runs in. `setup` needs an UNPROVISIONED one: the fixture above carries a
# rendered .env, and setup refuses a non-interactive re-run before it reaches its window — so
# driven there it would report "did not wait" for a reason that has nothing to do with the lock.
LKWDIR="$LKW"
LKWFRESH="$LKW/fresh"
LKWAPPLY="$LKW/applying"
LKWBAL="$LKW/balance"
LKWSETUP="$LKW/setupprompt"
mkdir -p "$LKWFRESH"

lock_wiring_probe() { # <lock file> <fn> [args...] -> "<timedout|ran>+<mutated|untouched>"
    local lk="$1" log="$LKW/wiring-docker.log" out t=ran m=untouched
    shift
    : >"$log"
    out=$(cd "$LKWDIR" && PITHEAD_LOCK_FILE="$lk" PITHEAD_LOCK_TIMEOUT=1 PITHEAD_APPLIANCE=0 \
        DOCKER_LOG="$log" PATH="$LKW/bin:$PATH" \
        env -u PITHEAD_LOCK_HELD bash -c 'source "$1"; set +e; shift; "$@"' _ "$STACK" "$@" 2>&1)
    case "$out" in *"waiting up to"*) t=timedout ;; esac
    # Only the MUTATING compose calls: `backup` runs `compose ps` to decide whether the stack is
    # up before it takes the window, and a read-only query is not a mutation.
    grep -Eq 'compose (up|down|stop|create|restart)' "$log" 2>/dev/null && m=mutated
    printf '%s+%s' "$t" "$m"
}
# The pair, per verb, in one assertion: refuses against a held window and touches nothing, and
# gets PAST the lock when nothing holds it. The second half is the control — without it
# "timed out" would also be true of a verb that cannot run in this fixture at all.
lock_wiring_pair() { # <fn> [args...] -> "<held>|<free timed out?>"
    local held free
    held=$(lock_wiring_probe "$LKWHELD" "$@")
    rm -f "$LKWFREE"
    free=$(lock_wiring_probe "$LKWFREE" "$@")
    rm -f "$LKWFREE"
    printf '%s|%s' "$held" "${free%%+*}"
}
# One holder for all six pairs below. `flock -w`, not `flock -n`: the readiness poll under it
# takes the lock itself to test for it, and a non-blocking holder that loses that race exits —
# leaving every case below to pass against a lock nobody held. Bounded, so a genuinely stuck
# fixture is reported by the guard below instead of hanging the suite.
: >"$LKWHELD"
(
    exec 9>>"$LKWHELD"
    flock -w 20 9 || exit 1
    exec sleep 120
) &
LKWHOLDER=$!
i=0
while [ "$i" -lt 200 ]; do
    flock -n "$LKWHELD" true 2>/dev/null || break
    sleep 0.05
    i=$((i + 1))
done
# The wiring cases are only evidence while this holds — say so rather than reporting six passes
# earned by an absent holder.
if flock -n "$LKWHELD" true 2>/dev/null; then
    bad "the holder for the verb-wiring cases takes the window" "the lock is free, so the six cases below prove nothing"
fi
assert_eq "up waits on a held window and changes nothing" "$(lock_wiring_pair stack_up)" "timedout+untouched|ran"
assert_eq "upgrade waits on a held window and changes nothing" "$(lock_wiring_pair stack_upgrade)" "timedout+untouched|ran"
LKWDIR="$LKWFRESH"
assert_eq "setup waits on a held window and changes nothing" "$(lock_wiring_pair setup)" "timedout+untouched|ran"
LKWDIR="$LKW"
assert_eq "restore waits on a held window and changes nothing" \
    "$(lock_wiring_pair stack_restore -y "$LKW/wiring-archive.tar.gz")" "timedout+untouched|ran"
assert_eq "backup waits on a held window and changes nothing" \
    "$(lock_wiring_pair stack_backup -y --no-encrypt)" "timedout+untouched|ran"
# apply takes the window in THREE places and the shared fixture reaches exactly one of them:
# five free-runs have re-rendered its .env by now, so apply finds nothing to change and returns
# on the no-change branch. Drive all three, each on the fixture it needs. Until this split,
# DELETING either of the other two acquires outright left this whole file green.
assert_eq "apply waits on a held window when it has nothing to change" "$(lock_wiring_pair apply -y)" "timedout+untouched|ran"
lock_wiring_fixture "$LKWAPPLY"
LKWDIR="$LKWAPPLY"
assert_eq "apply waits on a held window before it commits a change" "$(lock_wiring_pair apply -y)" "timedout+untouched|ran"
# The third window is the retry branch — a previous apply committed the config and then failed to
# recreate. That state is what this fixture is in now (the free run above re-rendered its .env),
# so arming the marker is the whole setup. Nothing else in this file reaches that acquire:
# deleting it leaves every other case green, which is how it stayed unguarded until now.
: >"$LKWAPPLY/.env.apply-incomplete"
assert_eq "apply waits on a held window while it retries a failed recreate" "$(lock_wiring_pair apply -y)" "timedout+untouched|ran"
LKWDIR="$LKW"
kill "$LKWHOLDER" 2>/dev/null
wait "$LKWHOLDER" 2>/dev/null

# The other half of the wiring: a verb that finishes must hand the lock back exactly once. A
# missing release leaves the window open for the rest of the process, and a DOUBLE acquire leaves
# the depth counter at 1 with nothing left to decrement it — the failure the `apply` retry-branch
# guard exists to prevent. Neither is visible from outside the process, because the kernel drops
# the hold when it exits; both are visible from inside it.
lock_wiring_balance() { # <fn> [args...] -> "depth=<n> state=<free|held>"
    # Use a fresh fixture: a completed apply rewrites .env and cannot reach the retry branch again.
    rm -rf "$LKWBAL"
    lock_wiring_fixture "$LKWBAL"
    rm -f "$LKWFREE"
    (cd "$LKWBAL" && PITHEAD_LOCK_FILE="$LKWFREE" PITHEAD_APPLIANCE=0 DOCKER_LOG=/dev/null \
        PATH="$LKW/bin:$PATH" env -u PITHEAD_LOCK_HELD \
        bash -c 'source "$1"; set +e; shift; "$@" >/dev/null 2>&1
                 st=free; flock -n "$PITHEAD_LOCK_FILE" true 2>/dev/null || st=held
                 printf "depth=%s state=%s" "$_PITHEAD_LOCK_DEPTH" "$st"' _ "$STACK" "$@") 2>/dev/null
}
assert_eq "up gives its window back when it finishes" "$(lock_wiring_balance stack_up)" "depth=0 state=free"
assert_eq "upgrade gives its window back when it finishes" "$(lock_wiring_balance stack_upgrade)" "depth=0 state=free"
assert_eq "backup gives its window back when it finishes" \
    "$(lock_wiring_balance stack_backup -y --no-encrypt)" "depth=0 state=free"
assert_eq "restore gives its window back when it finishes" \
    "$(lock_wiring_balance stack_restore -y "$LKWBAL/wiring-archive.tar.gz")" "depth=0 state=free"
assert_eq "apply takes its window once and gives it back, however it reached the recreate" \
    "$(lock_wiring_balance apply -y)" "depth=0 state=free"
# restart is the sixth verb with a window and the only one the block above did not name. Nothing
# else in this file reaches its release either: the four restart cases at the top of the file
# assert what it restarted, not what it did with the lock, so deleting stack_restart's
# `mutation_lock_release` left every case in this file green.
assert_eq "restart gives its window back when it finishes" \
    "$(lock_wiring_balance stack_restart)" "depth=0 state=free"

# SETUP'S RELEASE — its own probe, because a balance case cannot reach it.
#
# setup's release is not at the end of the verb. It sits BEFORE the interactive "start now?",
# and setup's own comment says why: everything below it is a message or a human wait, and the
# firstboot wizard runs `(setup)` in a subshell, so a hold spanning the prompt would park the
# window on an absent operator while pithead-boot's `up` timed out against it. The property is
# therefore an ORDERING — released BEFORE the wait — which an end-state balance cannot see.
#
# Nor can a balance case be driven here at all: setup refuses a non-interactive re-run against a
# provisioned dir before it ever reaches its window (which is why the pair case above needs the
# fresh dir), and against a fresh one it would run the entire wizard. So the probe stubs the
# provisioning body — every step between the acquire and the release — and leaves the LOCK
# WIRING real, which is the only thing under test. prompt_start_stack becomes the probe itself,
# reporting whether the window was free at the instant setup reached the human wait.
#
# REACHING the probe is the anti-vacuity control: if the stubs ever stop letting setup through,
# nothing prints and the assertion fails on an empty string instead of passing on a run that
# never got there. The end-state half is read too, so a release that moved rather than vanished
# still shows up.
lock_wiring_setup_prompt() { # -> "at-prompt=<free|held> depth=<n> state=<free|held>"
    rm -rf "$LKWSETUP"
    mkdir -p "$LKWSETUP"
    rm -f "$LKWFREE"
    (cd "$LKWSETUP" && PITHEAD_LOCK_FILE="$LKWFREE" PITHEAD_APPLIANCE=0 DOCKER_LOG=/dev/null \
        PATH="$LKW/bin:$PATH" env -u PITHEAD_LOCK_HELD \
        bash -c 'source "$1"; set +e
            for f in check_prerequisites ensure_config_exists ensure_onion_password \
                parse_and_validate_config preflight_resources check_stratum_exposure \
                load_preserved_state resolve_dashboard_host prepare_directories render_env \
                provision_tor inject_service_configs optimize_kernel generate_caddyfile \
                provision_control_runner render_local_miner_config update_current_symlink \
                provision_local_miner; do eval "$f() { :; }"; done
            prompt_start_stack() {
                st=free; flock -n "$PITHEAD_LOCK_FILE" true 2>/dev/null || st=held
                printf "at-prompt=%s " "$st" >&3
            }
            setup >/dev/null 2>&1
            st=free; flock -n "$PITHEAD_LOCK_FILE" true 2>/dev/null || st=held
            printf "depth=%s state=%s" "$_PITHEAD_LOCK_DEPTH" "$st" >&3' _ "$STACK" 3>&1) 2>/dev/null
}
assert_eq "setup hands its window back BEFORE the interactive start prompt" \
    "$(lock_wiring_setup_prompt)" "at-prompt=free depth=0 state=free"

# THE RUNNING-STACK BACKUP BRANCH — unreachable by every case above, and that is the point.
#
# stack_backup takes the window in TWO places, chosen on `docker compose ps --status running -q`.
# make_stubs' docker (tests/stack/lib.sh) has NO case arm for that query and falls through to
# `exit 0` with empty stdout, so `running` is always empty and BOTH backup cases above take the
# stack-already-stopped branch. Deleting the running branch's acquire outright left this whole
# file green — the same shape as apply's two unreached windows, and it hides more: without it the
# archive is taken in a THIRD window rather than one, with `tar` running UNLOCKED between
# stack_down's release and stack_up's re-acquire. A concurrent setup or apply can then bring
# containers up mid-archive, which is a torn backup — #970's retry failure mode arriving for a
# reason the retry cannot fix.
#
# A balance case CANNOT see this: with or without that acquire the verb ends depth=0 and free. The
# property that discriminates is WHEN the window is held, so the probe asks the only question that
# separates them — was it held at the moment the archive was taken?
LKWRUN="$LKW/runningstack"
LKWRUNLK="$LKW/running.lock"
lock_backup_running_probe() { # -> "<which branch>|<window while the archive is taken>"
    local log="$LKWRUN/docker.log" branch=stopped
    rm -rf "$LKWRUN"
    lock_wiring_fixture "$LKWRUN"
    mkdir -p "$LKWRUN/bin"
    : >"$log"
    rm -f "$LKWRUNLK" "$LKWRUN/window"
    # A docker that reports a RUNNING stack — the one answer the shared stub cannot give.
    cat >"$LKWRUN/bin/docker" <<'DOCKEREOF'
#!/usr/bin/env bash
echo "[docker] $*" >>"${DOCKER_LOG:-/dev/null}"
case "$*" in
"compose ps --status running -q") echo "c0ffeec0ffee" ;;
esac
exit 0
DOCKEREOF
    # A sudo that runs nothing and records whether the mutation window is held at the instant the
    # archive is taken. `flock -n` from this child opens its OWN descriptor, so the parent's fd 9
    # hold denies it — the same mechanism the balance cases use to read the lock's state.
    cat >"$LKWRUN/bin/sudo" <<'SUDOEOF'
#!/usr/bin/env bash
case "$1" in
tar)
    if flock -n "$PITHEAD_LOCK_FILE" true 2>/dev/null; then
        printf 'free' >"$WINDOW_OUT"
    else
        printf 'held' >"$WINDOW_OUT"
    fi
    ;;
esac
exit 0
SUDOEOF
    chmod +x "$LKWRUN/bin/docker" "$LKWRUN/bin/sudo"
    (cd "$LKWRUN" && PITHEAD_LOCK_FILE="$LKWRUNLK" PITHEAD_APPLIANCE=0 DOCKER_LOG="$log" \
        WINDOW_OUT="$LKWRUN/window" PATH="$LKWRUN/bin:$PATH" env -u PITHEAD_LOCK_HELD \
        bash -c 'source "$1"; set +e; shift; "$@"' _ "$STACK" \
        stack_backup -y --no-encrypt) >/dev/null 2>&1
    # Which branch actually ran, read from the stack having been STOPPED for the backup. Without
    # this half the row is vacuous in exactly the way it exists to fix: if the stub ever stops
    # answering the query, the stopped branch takes its own window, the archive is still taken
    # under it, and a "held" verdict would read as coverage of a branch that never ran.
    grep -Eq 'compose .*\bdown\b' "$log" 2>/dev/null && branch=running
    printf '%s|%s' "$branch" "$(cat "$LKWRUN/window" 2>/dev/null || printf 'never-archived')"
}
assert_eq "a backup that stops a running stack holds one window across the archive" \
    "$(lock_backup_running_probe)" "running|held"
unset -f lock_backup_running_probe

unset -f lock_hold_bg lock_await_record lock_state lock_held lock_reinvoke_probe lock_nest_probe reinvoke_wiring_probe
unset -f lock_sibling_probe lock_wiring_fixture lock_wiring_probe lock_wiring_pair lock_wiring_balance
