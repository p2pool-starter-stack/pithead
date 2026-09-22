# shellcheck shell=bash
: "${STACK_SUITE:?is unset: this file is a tests/stack/run.sh fragment, not a script — run tests/stack/run.sh}"
# Control-deploy domain (#1105 Phase 1, module 9): the bundle-deploy layout mechanics —
# update_current_symlink's `current ->` pointer, migrate_dashboard_data's move/warn/conflict
# rules for the pre-#455 in-install-dir default, and their end-to-end wiring through a real
# deploy-box layout (shared data root outside the version dir). All three sections are fully
# self-contained (their own throwaway sandboxes under $SANDBOX) — no shared control/config
# sandbox, no re-derivation needed. Sourced by tests/stack/run.sh after lib.sh.

echo "== unit: update_current_symlink (#455) =="
# A non-versioned install dir (source checkout, plain `pithead/` extract) gets NO symlink —
# `current` only makes sense beside pithead-vX.Y.Z version dirs.
mkdir -p "$SANDBOX/plainroot/pithead"
run_sourced "$SANDBOX/plainroot/pithead" update_current_symlink >/dev/null 2>&1
if [ -e "$SANDBOX/plainroot/current" ]; then
    bad "no current symlink for a non-versioned dir" "created $SANDBOX/plainroot/current"
else
    ok "no current symlink for a non-versioned dir"
fi

# A versioned dir gets `../current -> <dirname>` (relative target, so the tree can move).
mkdir -p "$SANDBOX/deployroot/pithead-v9.9.9" "$SANDBOX/deployroot/pithead-v9.9.10"
run_sourced "$SANDBOX/deployroot/pithead-v9.9.9" update_current_symlink >/dev/null 2>&1
assert_eq "current -> pithead-v9.9.9 after first run" "$(readlink "$SANDBOX/deployroot/current")" "pithead-v9.9.9"
# Re-pointing: a later version dir takes over the same symlink (ln -sfn, no stale nesting).
run_sourced "$SANDBOX/deployroot/pithead-v9.9.10" update_current_symlink >/dev/null 2>&1
assert_eq "current re-pointed to pithead-v9.9.10" "$(readlink "$SANDBOX/deployroot/current")" "pithead-v9.9.10"
# Idempotent re-run keeps it.
run_sourced "$SANDBOX/deployroot/pithead-v9.9.10" update_current_symlink >/dev/null 2>&1
assert_eq "current unchanged on re-run" "$(readlink "$SANDBOX/deployroot/current")" "pithead-v9.9.10"

# `current` existing as a REAL directory is never clobbered (ln -sfn would nest a link inside it).
mkdir -p "$SANDBOX/dirroot/pithead-v1.2.3" "$SANDBOX/dirroot/current"
out="$(run_sourced "$SANDBOX/dirroot/pithead-v1.2.3" update_current_symlink 2>&1)"
rc=$?
assert_rc "real-dir current: still rc 0 (never fails the upgrade)" "$rc" "0"
assert_contains "real-dir current: warns" "$out" "not a symlink"
if [ -d "$SANDBOX/dirroot/current" ] && [ ! -L "$SANDBOX/dirroot/current" ]; then
    ok "real-dir current left untouched"
else
    bad "real-dir current left untouched" "was replaced"
fi

echo "== unit: migrate_dashboard_data (#455) =="
# Direct unit calls with the parse-time globals set by hand; docker stubbed (no daemon in tests).
mig455() { # <workdir> <DASHBOARD_DIR> <is_default>
    (
        cd "$1" || exit 1
        # shellcheck disable=SC1090
        source "$STACK"
        set +e
        docker() { :; }
        # shellcheck disable=SC2034  # read by the sourced migrate_dashboard_data
        DASHBOARD_DIR="$2"
        # shellcheck disable=SC2034
        DASHBOARD_DIR_IS_DEFAULT="$3"
        migrate_dashboard_data
    )
}
M="$SANDBOX/mig"
mkdir -p "$M/data/dashboard" "$M/shared"
printf 'olddb' >"$M/data/dashboard/mining_data.db"
# move-if-default: the old in-install-dir data moves to the shared-root default, DB intact.
out="$(mig455 "$M" "$M/shared/dashboard" 1 2>&1)"
assert_rc "move-if-default succeeds" "$?" "0"
assert_eq "DB moved intact" "$(cat "$M/shared/dashboard/mining_data.db" 2>/dev/null)" "olddb"
if [ -e "$M/data/dashboard" ]; then bad "old default gone after move" "still exists"; else ok "old default gone after move"; fi
# idempotent: nothing at the old default any more -> silent no-op.
out="$(mig455 "$M" "$M/shared/dashboard" 1 2>&1)"
assert_rc "re-run is a no-op" "$?" "0"
assert_eq "DB survives the re-run" "$(cat "$M/shared/dashboard/mining_data.db" 2>/dev/null)" "olddb"
# warn-if-custom: an operator-pinned dashboard.data_dir is never migrated — warn and leave both.
mkdir -p "$M/data/dashboard"
printf 'olddb2' >"$M/data/dashboard/mining_data.db"
out="$(mig455 "$M" "$M/pinned" 0 2>&1)"
assert_rc "custom path: rc 0" "$?" "0"
assert_contains "custom path: warns about the leftover" "$out" "$M/data/dashboard"
assert_eq "custom path: old data untouched" "$(cat "$M/data/dashboard/mining_data.db")" "olddb2"
if [ -e "$M/pinned/mining_data.db" ]; then bad "custom path: nothing moved" "moved anyway"; else ok "custom path: nothing moved"; fi
# conflict: data at BOTH locations -> hard stop, nothing touched (never guess which DB is live).
out="$(mig455 "$M" "$M/shared/dashboard" 1 2>&1)"
assert_rc "both-populated: refuses" "$?" "1"
assert_eq "both-populated: old DB untouched" "$(cat "$M/data/dashboard/mining_data.db")" "olddb2"
assert_eq "both-populated: new DB untouched" "$(cat "$M/shared/dashboard/mining_data.db")" "olddb"
# empty pre-created target (an earlier ensure_directories mkdir) is not a conflict — the move runs.
rm -f "$M/shared/dashboard/mining_data.db"
out="$(mig455 "$M" "$M/shared/dashboard" 1 2>&1)"
assert_rc "empty pre-created target: move succeeds" "$?" "0"
assert_eq "empty pre-created target: DB moved" "$(cat "$M/shared/dashboard/mining_data.db" 2>/dev/null)" "olddb2"

# Wiring: stack_upgrade migrates BEFORE the containers are recreated and points `current` at the
# install only AFTER a successful 'compose up' — a failed upgrade must not move the pointer.
upg455_order=$(
    cd "$SANDBOX" || exit
    # shellcheck disable=SC1090
    source "$STACK"
    set +e
    require_env() { :; }
    ensure_onion_password() { :; }
    parse_and_validate_config() { :; }
    load_preserved_state() { :; }
    ensure_directories() { :; }
    resolve_dashboard_host() { :; }
    render_env() { :; }
    mv() { :; }
    inject_service_configs() { :; }
    generate_caddyfile() { :; }
    provision_control_runner() { :; }
    migrate_compose_project() { :; }
    is_source_checkout() { return 0; }
    log() { :; }
    docker() { :; }
    apply_tor_egress_firewall() { :; }
    migrate_dashboard_data() { echo migrate; }
    update_current_symlink() { echo symlink; }
    compose_up_checked() { echo compose; }
    stack_upgrade
)
assert_eq "upgrade: migrate -> compose -> symlink (#455)" \
    "$(printf '%s\n' "$upg455_order" | grep -xE 'migrate|compose|symlink' | tr '\n' ',')" "migrate,compose,symlink,"
upg455_fail=$(
    cd "$SANDBOX" || exit
    # shellcheck disable=SC1090
    source "$STACK"
    set +e
    require_env() { :; }
    ensure_onion_password() { :; }
    parse_and_validate_config() { :; }
    load_preserved_state() { :; }
    ensure_directories() { :; }
    resolve_dashboard_host() { :; }
    render_env() { :; }
    mv() { :; }
    inject_service_configs() { :; }
    generate_caddyfile() { :; }
    provision_control_runner() { :; }
    migrate_compose_project() { :; }
    is_source_checkout() { return 0; }
    log() { :; }
    docker() { :; }
    apply_tor_egress_firewall() { :; }
    migrate_dashboard_data() { :; }
    update_current_symlink() { echo symlink; }
    compose_up_checked() { return 1; }
    stack_upgrade
)
assert_not_contains "failed upgrade does NOT move the current pointer (#455)" "$upg455_fail" "symlink"

echo "== unit: carry_dashboard_data_move (#2360) =="
# Direct unit calls, mirroring mig455 above: a confirmed A-to-B dashboard.data_dir move, distinct
# from the #455 default migration — this one COPIES (never moves) and verifies by content.
carry2360() { # <workdir> <old> <new>
    (
        cd "$1" || exit 1
        # shellcheck disable=SC1090
        source "$STACK"
        set +e
        docker() { :; }
        carry_dashboard_data_move "$2" "$3"
    )
}
C="$SANDBOX/carry"
mkdir -p "$C/old" "$C/new"
printf 'livedb' >"$C/old/mining_data.db"
printf 'wal-bytes' >"$C/old/mining_data.db-wal"
rmdir "$C/new" # an unpopulated pre-created target (ensure_directories) is not a conflict
out="$(carry2360 "$C" "$C/old" "$C/new" 2>&1)"
assert_rc "carry: succeeds" "$?" "0"
assert_eq "carry: DB copied intact" "$(cat "$C/new/mining_data.db" 2>/dev/null)" "livedb"
assert_eq "carry: -wal companion copied" "$(cat "$C/new/mining_data.db-wal" 2>/dev/null)" "wal-bytes"
assert_eq "carry: old copy left in place (never moved)" "$(cat "$C/old/mining_data.db" 2>/dev/null)" "livedb"
# no DB at the old path: nothing live there, silent no-op.
mkdir -p "$C/empty-old" "$C/empty-new"
out="$(carry2360 "$C" "$C/empty-old" "$C/empty-new" 2>&1)"
assert_rc "carry: no DB at old path is a no-op" "$?" "0"
if [ -e "$C/empty-new/mining_data.db" ]; then bad "carry: nothing created with no source DB" "created anyway"; else ok "carry: nothing created with no source DB"; fi
# non-empty target: refuse rather than guess which DB is live; old untouched.
mkdir -p "$C/old2" "$C/occupied"
printf 'srcdb' >"$C/old2/mining_data.db"
printf 'existing' >"$C/occupied/mining_data.db"
out="$(carry2360 "$C" "$C/old2" "$C/occupied" 2>&1)"
assert_rc "carry: non-empty target refuses" "$?" "1"
assert_contains "carry: refusal names the target" "$out" "$C/occupied"
assert_eq "carry: target DB untouched by refusal" "$(cat "$C/occupied/mining_data.db")" "existing"
assert_eq "carry: source DB untouched by refusal" "$(cat "$C/old2/mining_data.db")" "srcdb"
# target nested under the live directory: refuse before a copy can be mistaken for live state.
mkdir -p "$C/old-nested/target"
printf 'nesteddb' >"$C/old-nested/mining_data.db"
out="$(carry2360 "$C" "$C/old-nested" "$C/old-nested/target" 2>&1)"
assert_rc "carry: nested target refuses" "$?" "1"
assert_eq "carry: nested refusal leaves source untouched" "$(cat "$C/old-nested/mining_data.db")" "nesteddb"
# stop must succeed before copying an SQLite DB; do not snapshot a live WAL set.
mkdir -p "$C/old-stop" "$C/new-stop"
printf 'stopdb' >"$C/old-stop/mining_data.db"
out="$({
    cd "$C" || exit 1
    # shellcheck disable=SC1090
    source "$STACK"
    set +e
    docker() { return 1; }
    carry_dashboard_data_move "$C/old-stop" "$C/new-stop"
} 2>&1)"
assert_rc "carry: stop failure refuses" "$?" "1"
if [ -e "$C/new-stop/mining_data.db" ]; then bad "carry: stop failure does not copy" "copied anyway"; else ok "carry: stop failure does not copy"; fi
# corrupted/short copy: cmp catches it, refuses, source untouched (simulates a failed/partial cp).
mkdir -p "$C/old3" "$C/new3"
printf 'realdb' >"$C/old3/mining_data.db"
rmdir "$C/new3"
out="$({
    cd "$C" || exit 1
    # shellcheck disable=SC1090
    source "$STACK"
    set +e
    docker() { printf '%s\n' "$*" >"$C/dashboard-restart"; }
    cp() { : >"${*: -1}"; } # a copy that silently truncates its DEST (cp -p, so $2 is -p's src) — must be CAUGHT, not trusted
    carry_dashboard_data_move "$C/old3" "$C/new3"
} 2>&1)"
rc=$? # error() exits the subshell directly — capture ITS status, not a $? that never runs
assert_rc "carry: verifies the copy (doesn't trust cp alone)" "$rc" "1"
assert_contains "carry: restarts dashboard after a failed verify" "$(cat "$C/dashboard-restart")" "compose start dashboard"
if [ -e "$C/old3/mining_data.db" ] && [ "$(cat "$C/old3/mining_data.db")" = "realdb" ]; then
    ok "carry: source untouched after a failed verify"
else
    bad "carry: source untouched after a failed verify" "source was altered"
fi
# A successful main-DB copy is not enough: SQLite's WAL must verify too.
mkdir -p "$C/old-wal" "$C/new-wal"
printf 'waldb' >"$C/old-wal/mining_data.db"
printf 'livewal' >"$C/old-wal/mining_data.db-wal"
out="$({
    cd "$C" || exit 1
    # shellcheck disable=SC1090
    source "$STACK"
    set +e
    docker() { printf '%s\n' "$*" >"$C/dashboard-wal-restart"; }
    cp() { [ "$3" = "$C/old-wal/mining_data.db-wal" ] && : >"$4" || command cp "$@"; }
    carry_dashboard_data_move "$C/old-wal" "$C/new-wal"
} 2>&1)"
assert_rc "carry: verifies the WAL companion" "$?" "1"
assert_contains "carry: restarts dashboard after a WAL verify failure" "$(cat "$C/dashboard-wal-restart")" "compose start dashboard"

echo "== unit: apply wiring for carry_dashboard_data_move (#2360) =="
# A changed DASHBOARD_DATA_DIR must reach the carry with the OLD (pre-commit) and NEW paths before
# committing the new env or recreating compose. An unchanged data_dir must not call it.
apply2360() { # <extra-stub-body>
    (
        cd "$SANDBOX/apply2360" || exit 1
        # shellcheck disable=SC1090
        source "$STACK"
        set +e
        require_env() { :; }
        ensure_onion_password() { :; }
        load_preserved_state() { :; }
        ensure_directories() { :; }
        resolve_dashboard_host() { :; }
        is_deployed() { return 0; }
        onion_missing() { return 1; }
        # shellcheck disable=SC2034  # read by the sourced apply()'s "not provisioned" guard
        P2POOL_ONION=p2pa.onion
        inject_service_configs() { :; }
        generate_caddyfile() { :; }
        provision_control_runner() { :; }
        provision_onion_client_auth() { :; }
        provision_ssh_access() { :; }
        provision_console_login() { :; }
        render_local_miner_config() { :; }
        migrate_compose_project() { :; }
        apply_tor_egress_firewall() { :; }
        reconcile_appliance_hostname() { :; }
        migrate_dashboard_data() { echo migrate; }
        compose_up_checked() {
            echo compose
            return 0
        }
        mutation_lock_acquire() { :; }
        mutation_lock_release() { :; }
        env_changed_keys() { printf 'DASHBOARD_DATA_DIR\n'; }
        env_get_file() { [ "$1" = "$ENV_FILE" ] && echo "/old/path" || echo "/new/path"; }
        describe_change() { printf 'CONFIRM\tdata dir changed\n'; }
        render_env() { :; }
        # shellcheck disable=SC2034  # read by the sourced apply/carry_dashboard_data_move
        parse_and_validate_config() { DASHBOARD_DIR="/new/path"; }
        carry_dashboard_data_move() {
            echo "carry:$1:$2"
            [ "${CARRY2360_FAIL:-}" = 1 ] && exit 1
        }
        mv() { echo mv; }
        apply -y
    )
}
mkdir -p "$SANDBOX/apply2360"
: >"$SANDBOX/apply2360/.env"
out="$(apply2360 2>&1)"
assert_contains "apply: carries with the pre-commit old path" "$out" "carry:/old/path:/new/path"
assert_eq "apply: carry runs before committing the new env and compose" \
    "$(printf '%s\n' "$out" | grep -xE 'carry:/old/path:/new/path|mv|migrate|compose' | tr '\n' ',')" \
    "carry:/old/path:/new/path,mv,migrate,compose,"
out="$(CARRY2360_FAIL=1 apply2360 2>&1)"
assert_rc "apply: failed carry refuses the env switch" "$?" "1"
assert_not_contains "apply: failed carry never commits the new env" "$out" "mv"

echo "== black-box: deploy-box layout (#455) =="
# A sandboxed source-checkout install whose chain data dirs share one root — the live deploy-box
# layout. Proves the default resolution, the apply-time migration, and the upgrade-time
# symlink end to end through the real CLI (docker/sudo stubbed).
L="$SANDBOX/boxroot/pithead-v9.9.9"
mkdir -p "$L/build/tari" "$L/dashboard"
: >"$L/dashboard/Dockerfile"
cp "$STACK" "$L/pithead"
make_stubs "$L/bin"
cp "$ROOT/build/tari/config.toml.template" "$L/build/tari/"
SHARED="$SANDBOX/boxroot/data"
seed_L() {
    cat >"$L/.env" <<EOF
MONERO_ONION_ADDRESS=mona.onion
TARI_ONION_ADDRESS=taria.onion
P2POOL_ONION_ADDRESS=p2pa.onion
PROXY_AUTH_TOKEN=ORIGINALTOKEN
HOST_IP=box.lan
DEPLOYMENT_COMPLETED=true
COMPOSE_PROFILES=local_node
EOF
}
cfg_L() { # <dashboard-extra-json>  e.g. ',"data_dir":"/pinned"'
    # $VALID_PRIMARY, not $WALLET: same trap as modules 7/8 -- $WALLET is only assigned inside
    # build_val_sandbox() (lib.sh), never called in this file, and $VALID_PRIMARY is the lib.sh
    # top-level fixture WALLET equals in that function's local/checksum-valid case.
    printf '{ "monero": {"mode":"local","wallet_address":"%s","node_username":"u","node_password":"p","data_dir":"%s/monero"}, "tari":{"wallet_address":"'"$VALID_TARI"'","data_dir":"%s/tari"}, "p2pool":{"pool":"main","data_dir":"%s/p2pool"}, "tor":{"data_dir":"%s/tor"}, "dashboard":{"secure":true,"host":"box.lan"%s} }\n' \
        "$VALID_PRIMARY" "$SHARED" "$SHARED" "$SHARED" "$SHARED" "$1" >"$L/config.json"
}
# Old layout on disk: the dashboard DB inside the version dir's ./data (the pre-#455 default).
seed_L
cfg_L ""
mkdir -p "$L/data/dashboard"
printf 'proddb' >"$L/data/dashboard/mining_data.db"
out="$(cd "$L" && PATH="$L/bin:$PATH" ./pithead apply -y 2>&1)"
assert_rc "apply with a shared data root succeeds" "$?" "0"
assert_eq "DASHBOARD_DATA_DIR joins the shared data root" \
    "$(run_sourced "$L" env_get_file "$L/.env" DASHBOARD_DATA_DIR)" "$SHARED/dashboard"
assert_eq "apply moved the dashboard DB to the shared root" \
    "$(cat "$SHARED/dashboard/mining_data.db" 2>/dev/null)" "proddb"
if [ -e "$L/data/dashboard" ]; then bad "apply: old in-version-dir data gone" "still exists"; else ok "apply: old in-version-dir data gone"; fi
# Re-apply: no config change, nothing to migrate — clean no-op.
out="$(cd "$L" && PATH="$L/bin:$PATH" ./pithead apply -y 2>&1)"
assert_rc "re-apply is a no-op" "$?" "0"
assert_eq "re-apply leaves the migrated DB alone" "$(cat "$SHARED/dashboard/mining_data.db")" "proddb"
# Upgrade from the versioned dir: maintains `current ->` beside it and stays idempotent.
out="$(cd "$L" && PATH="$L/bin:$PATH" ./pithead upgrade 2>&1)"
assert_rc "upgrade succeeds" "$?" "0"
assert_eq "upgrade maintains current -> pithead-v9.9.9" "$(readlink "$SANDBOX/boxroot/current")" "pithead-v9.9.9"
assert_eq "upgrade leaves the migrated DB alone" "$(cat "$SHARED/dashboard/mining_data.db")" "proddb"
# Scattered custom dirs (no single parent): the classic in-install ./data default stands.
seed_L
# $VALID_PRIMARY, not $WALLET -- same trap as above.
printf '{ "monero": {"mode":"local","wallet_address":"%s","node_username":"u","node_password":"p","data_dir":"%s/monero"}, "tari":{"wallet_address":"'"$VALID_TARI"'"}, "p2pool":{"pool":"main"}, "dashboard":{"secure":true,"host":"box.lan"} }\n' \
    "$VALID_PRIMARY" "$SHARED" >"$L/config.json"
out="$(cd "$L" && PATH="$L/bin:$PATH" ./pithead apply -y 2>&1)"
assert_rc "apply with scattered data dirs succeeds" "$?" "0"
assert_eq "no shared root -> dashboard default stays ./data/dashboard" \
    "$(run_sourced "$L" env_get_file "$L/.env" DASHBOARD_DATA_DIR)" "$L/data/dashboard"
