# shellcheck shell=bash
# shellcheck disable=SC2016 # the injected mv/cp wrappers are single-quoted on purpose: they expand inside run_sourced
#
# Restore-at-setup commit (#2689): restore_apply publishes the accepted items all or nothing. A
# failure part-way through the commit puts back every item it already replaced, removes what the
# chain merge added, and leaves no staged or set-aside copy behind. The pre-commit rejections
# (passphrase, layout, size) are test-appliance-restore.sh's; this file injects failures after
# validation, where the live side is already being written.
# Sourced by tests/stack/run.sh. $SANDBOX, $ROOT, $STACK, $VALID_TARI, $WALLET and the assertion
# helpers are lib.sh's; build_val_sandbox arms $WALLET the way test-appliance-restore.sh does.

build_val_sandbox

echo "== unit: restore_apply — a failure inside the commit rolls back (#2689) =="
RC="$(cd "$SANDBOX" && pwd -P)/restore-commit"
mkdir -p "$RC/build/tari" "$RC/bin"
cp "$STACK" "$RC/pithead"
cp "$ROOT/build/tari/config.toml.template" "$RC/build/tari/"
cp "$ROOT/docker-compose.yml" "$RC/docker-compose.yml"
printf '#!/usr/bin/env bash\nexit 0\n' >"$RC/bin/docker"
chmod +x "$RC/bin/docker"

# The archive: every replaced item, plus a chain tree with one name the target also holds and two
# (a file and a directory) that only the archive has.
RCA="$RC/archive-root"
mkdir -p "$RCA/${RC#/}/data/tor" "$RCA/${RC#/}/data/dashboard" "$RCA/${RC#/}/data/monero/sub"
printf '{ "monero": {"mode":"local","wallet_address":"%s","node_username":"u","node_password":"p"}, "tari":{"wallet_address":"%s"}, "p2pool":{"pool":"main"}, "dashboard":{"secure":true,"host":"archive.lan"} }\n' "$WALLET" "$VALID_TARI" >"$RCA/${RC#/}/config.json"
cat >"$RCA/${RC#/}/.env" <<'EOF'
MONERO_ONION_ADDRESS=dddddddddddddddddddddddddddddddddddddddddddddddddddddddd.onion
PROXY_AUTH_TOKEN=abcdef0123456789abcdef01
DEPLOYMENT_COMPLETED=true
EOF
printf 'ARCHIVE-CADDY\n' >"$RCA/${RC#/}/Caddyfile"
printf 'ARCHIVE-KEY\n' >"$RCA/${RC#/}/data/tor/hs_ed25519_secret_key"
printf 'ARCHIVE-DB\n' >"$RCA/${RC#/}/data/dashboard/dashboard.db"
printf 'ARCHIVE-CHAIN\n' >"$RCA/${RC#/}/data/monero/chain-state"
printf 'ARCHIVE-ONLY\n' >"$RCA/${RC#/}/data/monero/lmdb-sentinel"
printf 'ARCHIVE-ONLY\n' >"$RCA/${RC#/}/data/monero/sub/nested"
tar -czf "$RC/backup.tar.gz" -C "$RCA" "${RC#/}/config.json" "${RC#/}/.env" "${RC#/}/Caddyfile" \
    "${RC#/}/data/tor" "${RC#/}/data/dashboard" "${RC#/}/data/monero"
rm -rf "$RCA"

# The live side restore_apply must leave exactly as it found it when the commit fails.
rc_plant_live() {
    rm -rf "$RC/data" "$RC/config.json" "$RC/.env" "$RC/Caddyfile" "$RC/error"
    mkdir -p "$RC/data/tor" "$RC/data/dashboard" "$RC/data/monero"
    printf '{"live": true}\n' >"$RC/config.json"
    printf 'DEPLOYMENT_COMPLETED=true\nLIVE_ENV=1\n' >"$RC/.env"
    printf 'LIVE-CADDY\n' >"$RC/Caddyfile"
    printf 'LIVE-KEY\n' >"$RC/data/tor/hs_ed25519_secret_key"
    printf 'LIVE-DB\n' >"$RC/data/dashboard/dashboard.db"
    printf 'LIVE-CHAIN\n' >"$RC/data/monero/chain-state"
}
rc_live_state() {
    (cd "$RC" && cat config.json .env Caddyfile data/tor/hs_ed25519_secret_key data/dashboard/dashboard.db data/monero/chain-state 2>&1 &&
        find data -mindepth 1 | LC_ALL=C sort)
}
rc_leftovers() { find "$RC" -name '*.restore*' | LC_ALL=C sort; }
rc_apply() { # <shell text defining the injected failure>
    PATH="$RC/bin:$PATH" run_sourced "$RC" eval "$1"'
restore_apply "$PWD/backup.tar.gz" "" "$PWD/error"'
}
# Fails the swap of the staged dashboard tree into place (the last replaced item), after config.json,
# .env, Caddyfile and data/tor/ have already been swapped in.
RC_FAIL_DASHBOARD='mv() { [[ "${*: -1}" = "$PWD/data/dashboard" && "${*: -2:1}" = *.restore.* ]] && return 1; command mv "$@"; }'

rc_plant_live
rc_before=$(rc_live_state)
rc_apply "$RC_FAIL_DASHBOARD"
assert_rc "a commit that fails on data/dashboard/ reports failure" "$?" 1
assert_contains "the failed commit says nothing was changed" "$(cat "$RC/error")" 'nothing on this machine was changed'
assert_eq "a failed dashboard swap puts back config.json, .env, Caddyfile and the Tor keys" "$(rc_live_state)" "$rc_before"
assert_eq "a failed dashboard swap leaves no staged or set-aside copy" "$(rc_leftovers)" ""

# The last item, a chain merge, fails after copying: every replaced item comes back, the names the
# archive added are removed, and the target's own chain file is kept.
rc_plant_live
rc_apply 'cp() { command cp "$@"; [[ "$*" != *data/monero* ]]; }'
assert_rc "a commit whose chain merge fails reports failure" "$?" 1
assert_contains "the failed chain merge says nothing was changed" "$(cat "$RC/error")" 'nothing on this machine was changed'
assert_eq "a failed chain merge puts back every replaced item and removes what it added" "$(rc_live_state)" "$rc_before"
assert_eq "a failed chain merge leaves no staged or set-aside copy" "$(rc_leftovers)" ""

# A fresh machine has no data/ yet (#2051): the commit creates it and removes it again on rollback.
rc_plant_live
rm -rf "$RC/data"
rc_apply "$RC_FAIL_DASHBOARD"
assert_rc "a failed commit on a fresh machine reports failure" "$?" 1
assert_contains "the failed commit on a fresh machine says nothing was changed" "$(cat "$RC/error")" 'nothing on this machine was changed'
assert_eq "a failed commit removes the data directory it created" "$([ -e "$RC/data" ] || echo absent)" absent
assert_eq "a failed commit on a fresh machine keeps the live config.json" "$(cat "$RC/config.json")" '{"live": true}'
assert_eq "a failed commit on a fresh machine leaves no staged or set-aside copy" "$(rc_leftovers)" ""

# A failure while staging, before any swap, touches nothing live.
rc_plant_live
rc_apply 'install() { [[ "${*: -1}" = "$PWD"/Caddyfile.restore.* ]] && return 1; command install "$@"; }'
assert_rc "a commit that fails while staging the Caddyfile reports failure" "$?" 1
assert_contains "the failed staging says nothing was changed" "$(cat "$RC/error")" 'nothing on this machine was changed'
assert_eq "a failed staging leaves every live item as it was" "$(rc_live_state)" "$rc_before"
assert_eq "a failed staging leaves no staged or set-aside copy" "$(rc_leftovers)" ""

# Every previous copy comes back, but a staged copy cannot be removed: the error says what is left.
rc_plant_live
rc_apply "$RC_FAIL_DASHBOARD"'
rm() { [[ "${*: -1}" = "$PWD"/data/dashboard.restore.* ]] && return 1; command rm "$@"; }'
assert_rc "a commit whose staged copy outlives the rollback reports failure" "$?" 1
assert_contains "a leftover staged copy is named in the error" "$(cat "$RC/error")" 'look for .restore copies'
assert_eq "the staged copy that could not be removed is the one left" "$(rc_leftovers | sed "s|^$RC/||; s|restore\.[^/]*|restore.X|")" data/dashboard.restore.X
rm -rf "$RC"/data/dashboard.restore.*
assert_eq "a leftover staged copy still puts back every live item" "$(rc_live_state)" "$rc_before"

# When the rollback itself cannot put an item back, the previous copy stays beside it and the error
# says where to find it.
rc_plant_live
rc_apply 'mv() { [[ "${*: -1}" = "$PWD/data/dashboard" ]] && return 1; command mv "$@"; }'
assert_rc "a commit whose rollback fails reports failure" "$?" 1
assert_contains "a failed rollback names the .restore-old copies" "$(cat "$RC/error")" '.restore-old'
assert_eq "a failed rollback keeps the previous database beside its name" "$(cat "$RC"/data/dashboard.restore-old.*/dashboard.db)" LIVE-DB
assert_eq "a failed rollback still puts back the items before it" "$(cat "$RC/config.json" "$RC/data/tor/hs_ed25519_secret_key")" "$(printf '{"live": true}\nLIVE-KEY')"

# The same archive with nothing injected commits everything and deletes the set-aside copies.
rc_plant_live
rc_apply ':'
assert_rc "an uninjected commit succeeds" "$?" 0
assert_contains "the committed config.json is the archive's" "$(cat "$RC/config.json")" archive.lan
assert_eq "the committed Tor key and database are the archive's" "$(cat "$RC/data/tor/hs_ed25519_secret_key" "$RC/data/dashboard/dashboard.db")" "$(printf 'ARCHIVE-KEY\nARCHIVE-DB')"
assert_eq "the committed .env clears the source deployment marker" "$(sed -n 's/^DEPLOYMENT_COMPLETED=//p' "$RC/.env")" false
assert_eq "the committed chain merge keeps the target's file and adds the archive's" "$(cat "$RC/data/monero/chain-state" "$RC/data/monero/sub/nested")" "$(printf 'LIVE-CHAIN\nARCHIVE-ONLY')"
assert_eq "a committed restore leaves no staged or set-aside copy" "$(rc_leftovers)" ""
rm -rf "$RC"
unset -f rc_plant_live rc_live_state rc_leftovers rc_apply
