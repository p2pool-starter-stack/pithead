# shellcheck shell=bash
: "${STACK_SUITE:?is unset: this file is a tests/stack/run.sh fragment, not a script — run tests/stack/run.sh}"
# Restore-at-setup (#909, #786 B); build_val_sandbox makes this sourced domain independent.
build_val_sandbox
echo "== unit: firstboot_consume_restore — restore-at-setup (#909, #786 sub-issue B) =="
RS="$(cd "$SANDBOX" && pwd -P)/restore-consume"
mkdir -p "$RS/build/tari" "$RS/data/tor" "$RS/data/dashboard" "$RS/bin" "$RS/volatile" "$RS/stage"
export PITHEAD_RESTORE_STAGE_ROOT="$RS/stage"
cp "$STACK" "$RS/pithead" && cp "$ROOT/build/tari/config.toml.template" "$RS/build/tari/"
cat >"$RS/bin/docker" <<'EOF'
#!/usr/bin/env bash
case "$*" in
  "compose ps --status running -q") exit 0 ;; # empty output -> stack treated as not running
esac
exit 0
EOF
cat >"$RS/bin/sudo" <<'EOF'
#!/usr/bin/env bash
[ "$1" = "chown" ] && exit 0
exec "$@"
EOF
chmod +x "$RS/bin/docker" "$RS/bin/sudo"
cat >"$RS/.env" <<EOF
MONERO_ONION_ADDRESS=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa.onion
TARI_ONION_ADDRESS=bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb.onion
P2POOL_ONION_ADDRESS=cccccccccccccccccccccccccccccccccccccccccccccccccccccccc.onion
PROXY_AUTH_TOKEN=0123456789abcdef01234567
HOST_IP=box.lan
DEPLOYMENT_COMPLETED=true
COMPOSE_PROFILES=local_node
EOF
printf '{ "monero": {"mode":"local","wallet_address":"%s","node_username":"u","node_password":"p"}, "tari":{"wallet_address":"'"$VALID_TARI"'"}, "p2pool":{"pool":"main"}, "dashboard":{"secure":true,"host":"box.lan"} }\n' "$WALLET" >"$RS/config.json"
printf 'CADDY-ORIG\n' >"$RS/Caddyfile" && printf 'ONIONKEY-ORIG\n' >"$RS/data/tor/hs_ed25519_secret_key" && printf 'DBDATA-ORIG\n' >"$RS/data/dashboard/dashboard.db"
out="$(cd "$RS" && PATH="$RS/bin:$PATH" PITHEAD_BACKUP_PASSPHRASE=hunter2 ./pithead backup -y 2>&1)"
rc=$?
assert_rc "restore fixture: backup exits 0" "$rc" "0"
rarchive="$(ls "$RS"/backups/pithead-backup-*.tar.gz.enc 2>/dev/null | head -1)"
{ [ -n "$rarchive" ] && [ -f "$rarchive" ]; } && ok "restore fixture: encrypted archive created" || bad "restore fixture: encrypted archive created" "no .enc archive"
RSPOOL="$RS/data/firstboot-test"
mkdir -p "$RSPOOL" && rm -f "$RS/config.json"
cp "$rarchive" "$RSPOOL/restore-archive" && printf 'hunter2' >"$RSPOOL/restore-passphrase" # test fixture, not a real secret
out=$(cd "$RS" && PATH="$RS/bin:$PATH" run_sourced "$RS" eval 'mktemp() { case "$*" in -d\ *.restore.*) printf "%s\n" "$*" >>"$RS/stage-pattern" ;; esac; command mktemp "$@"; }; firstboot_consume_restore "$RSPOOL"' && echo rc0)
assert_contains "valid restore accepted" "$out" "rc0"
assert_eq "valid restore installs config.json" "$([ -f "$RS/config.json" ] && echo yes)" "yes"
assert_contains "valid restore carries the original wallet" "$(cat "$RS/config.json" 2>/dev/null)" "$WALLET"
assert_contains "valid restore regenerates the Caddyfile from config" "$(cat "$RS/Caddyfile" 2>/dev/null)" "reverse_proxy 127.0.0.1:8000"
assert_eq "valid restore brings back the dashboard db" "$(cat "$RS/data/dashboard/dashboard.db" 2>/dev/null)" "DBDATA-ORIG"
assert_eq "applied marker set" "$([ -f "$RSPOOL/applied" ] && echo yes)" "yes"
assert_eq "the archive is consumed" "$([ -f "$RSPOOL/restore-archive" ] || echo gone)" "gone"
assert_eq "the passphrase is never retained" "$([ -f "$RSPOOL/restore-passphrase" ] || echo gone)" "gone"
RH="$RS/stale-derived"
mkdir -p "$RH/${RS#/}" && cp "$RS/config.json" "$RH/${RS#/}/config.json"
cat >"$RH/${RS#/}/.env" <<'EOF'
PROXY_AUTH_TOKEN=abcdef0123456789abcdef01
MONERO_ONION_ADDRESS=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa.onion
TARI_ONION_ADDRESS=bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb.onion
P2POOL_ONION_ADDRESS=cccccccccccccccccccccccccccccccccccccccccccccccccccccccc.onion
ARCHIVE_ONLY_VALUE=stale-generated-setting
DASHBOARD_AUTH_HASH_B64=c3RhbGUtZml4dHVyZQ==
DASHBOARD_AUTH_PW_FP=stale-fingerprint
DEPLOYMENT_COMPLETED=true
EOF
printf 'STALE-GENERATED-CADDY\n' >"$RH/${RS#/}/Caddyfile"
tar -czf "$RSPOOL/restore-archive" -C "$RH" "${RS#/}/config.json" "${RS#/}/.env" "${RS#/}/Caddyfile" && : >"$RSPOOL/restore-passphrase" && rm -f "$RSPOOL/applied"
out=$(cd "$RS" && PATH="$RS/bin:$PATH" run_sourced "$RS" firstboot_consume_restore "$RSPOOL" && echo rc0)
assert_contains "wizard restore discards archive-derived policy" "$out" rc0
assert_eq "setup restore clears source deployment status" "$(sed -n 's/^DEPLOYMENT_COMPLETED=//p' "$RS/.env")" false
assert_eq "wizard restore preserves the generated proxy secret" "$(sed -n 's/^PROXY_AUTH_TOKEN=//p' "$RS/.env")" abcdef0123456789abcdef01
assert_not_contains "wizard restore drops unrecognized archive env policy" "$(cat "$RS/.env")" ARCHIVE_ONLY_VALUE
assert_eq "wizard restore derives disabled dashboard auth from config" "$(sed -n 's/^DASHBOARD_AUTH_HASH_B64=//p' "$RS/.env")" ""
assert_contains "wizard restore regenerates the dashboard proxy target" "$(cat "$RS/Caddyfile")" "reverse_proxy 127.0.0.1:8000"
assert_not_contains "wizard restore discards stale generated Caddy policy" "$(cat "$RS/Caddyfile")" STALE-GENERATED-CADDY
rm -rf "$RH"
rm -f "$RSPOOL/applied" "$RS/config.json" # clean slate for the rejection cases below
printf 'STICK-CADDY\n' >"$RS/Caddyfile"
printf 'STICK-DB\n' >"$RS/data/dashboard/dashboard.db"
cp "$rarchive" "$RSPOOL/restore-archive"
RSECRET="$RS/volatile/submission"
mkdir "$RSECRET"
printf 'hunter2' >"$RSECRET/restore-passphrase" # test fixture, not a real secret
RCARRY="$RS/volatile/carry"
RCANDIDATE="$RS/volatile/config.json"
out=$(cd "$RS" && PATH="$RS/bin:$PATH" PITHEAD_RESTORE_CARRY_DIR="$RCARRY" run_sourced "$RS" eval '
    mktemp() { case "$*" in -d\ *.restore.*) printf "%s\n" "$*" >>"$RS/stage-pattern" ;; esac; command mktemp "$@"; }
    firstboot_consume_restore "$RSPOOL" 1 "$RSECRET" "$RCANDIDATE"
' && echo rc0)
assert_contains "installer restore accepted" "$out" "rc0"
assert_contains "installer restore surfaces a volatile config for the card" "$(cat "$RCANDIDATE" 2>/dev/null)" "$WALLET"
assert_eq "installer restore leaves no config on the stick data" "$([ -e "$RS/config.json" ] || echo gone)" gone
assert_eq "installer restore does NOT restore onto the stick (Caddyfile untouched)" "$(cat "$RS/Caddyfile")" "STICK-CADDY"
assert_eq "installer restore does NOT restore onto the stick (db untouched)" "$(cat "$RS/data/dashboard/dashboard.db")" "STICK-DB"
assert_eq "accepted archive parked only in volatile carry" "$([ -f "$RCARRY/archive" ] && echo yes)" "yes"
assert_eq "passphrase parked only in volatile carry" "$(cat "$RCARRY/pass" 2>/dev/null)" "hunter2"
assert_eq "installer restore consumes the spool archive" "$([ -f "$RSPOOL/restore-archive" ] || echo gone)" "gone"
assert_eq "installer restore consumes the volatile submitted passphrase" "$([ -f "$RSECRET/restore-passphrase" ] || echo gone)" gone
cp "$rarchive" "$RSPOOL/restore-archive" && printf hunter2 >"$RSECRET/restore-passphrase"
RFAILCARRY="$RS/volatile/failure-carry"
RFAILCONFIG="$RS/volatile/failure-config.json"
out=$(cd "$RS" && PITHEAD_RESTORE_CARRY_DIR="$RFAILCARRY" run_sourced "$RS" eval 'wizard_spool_publish() { [ "$2" != restore-inflight ]; }; firstboot_consume_restore "$RSPOOL" 1 "$RSECRET" "$RFAILCONFIG" || echo "rc$?"')
assert_contains "marker publication failure rejects the restore" "$out" rc1
assert_eq "marker publication failure clears the volatile candidate" "$([ -e "$RFAILCONFIG" ] || echo gone)" gone
assert_eq "marker publication failure clears the volatile carry" "$([ -e "$RFAILCARRY" ] || echo gone)" gone
RDATA="$RS/target-data"
mkdir -p "$RDATA"
out=$(cd "$RS" && PATH="$RS/bin:$PATH" RDATA="$RDATA" run_sourced "$RS" eval '
    systemd-repart() { :; }
    udevadm() { :; }
    lsblk() { printf "/dev/fake4 data\n"; }
    mount() { local p="${*: -1}"; rmdir "$p" && ln -s "$RDATA" "$p"; }
    umount() { local p="$1"; rm "$p" && mkdir "$p"; }
    mktemp() { case "$*" in -d\ *.restore.*) printf "%s\n" "$*" >>"$RS/stage-pattern" ;; esac; command mktemp "$@"; }
    syncs=0
    sync() { syncs=$((syncs + 1)); [ "$syncs" -ne 2 ]; }
    if install_restore_to_target /dev/fake "$RCARRY" "$RCANDIDATE"; then echo unsafe-finalized; elif [ -f "$RDATA/pithead/.restore-incomplete" ]; then echo incomplete-kept; fi
    sync() { :; }
    install_restore_to_target /dev/fake "$RCARRY" "$RCANDIDATE" || exit
    mv "$RDATA/pithead" "$RDATA/restored"
    mkdir "$RDATA/outside"
    ln -s "$RDATA/outside" "$RDATA/pithead"
    if install_restore_to_target /dev/fake "$RCARRY" "$RCANDIDATE"; then echo symlink-accepted; else echo symlink-refused; fi
    rm "$RDATA/pithead"
    mv "$RDATA/restored" "$RDATA/pithead"
    ln -sf "$RDATA/outside/role" "$RDATA/pithead/machine-role"
    install_restore_to_target /dev/fake "$RCARRY" "$RCANDIDATE" || exit
    [ ! -e "$RDATA/outside/role" ] || echo leaf-written
    [ ! -f "$RDATA/pithead/.restore-pending" ] || echo pending-marker-kept
    clear_restore_stage() { warn "Could not clear the private restore staging area."; return 1; }
    if install_restore_to_target /dev/fake "$RCARRY" "$RCANDIDATE"; then echo stage-cleanup-accepted; elif [ -f "$RDATA/pithead/.restore-incomplete" ]; then echo stage-cleanup-refused; fi
' 2>&1 && echo rc0)
assert_contains "failed finalization leaves first boot fail-closed" "$out" incomplete-kept
assert_not_contains "failed finalization never reports a safe commit" "$out" unsafe-finalized
assert_contains "installer applies the volatile restore to target data" "$out" rc0
assert_contains "installer refuses a target data symlink escape" "$out" symlink-refused
assert_eq "target symlink refusal writes nothing outside the restore root" "$(find "$RDATA/outside" -mindepth 1 -print -quit)" ""
assert_not_contains "atomic role publication never follows a target leaf symlink" "$out" leaf-written
assert_contains "target rejects a restore whose plaintext stage cannot be cleared" "$out" stage-cleanup-refused
assert_not_contains "stage cleanup failure never reports a safe commit" "$out" stage-cleanup-accepted
assert_contains "target staging cleanup failure is generic" "$out" 'could not clear private restore staging safely'
assert_contains "target restore carries the original wallet" "$(cat "$RDATA/pithead/config.json")" "$WALLET"
assert_eq "target restore records the resolved machine role" "$(cat "$RDATA/pithead/machine-role")" pithead
assert_contains "target restore leaves only a non-secret pending marker" "$out" pending-marker-kept
assert_eq "a refused target restore disarms the pending marker" "$([ -e "$RDATA/pithead/.restore-pending" ] || echo gone)" gone
assert_eq "target data holds no persisted passphrase file" "$(find "$RDATA" -name '*restore-pass*' -print -quit)" ""
assert_eq "target data holds no second encrypted carry" "$(find "$RDATA" -name 'pithead-restore.enc' -print -quit)" ""
assert_contains "restore decrypt staging uses the dedicated volatile root" "$(cat "$RS/stage-pattern")" "-d $RS/stage/.restore.XXXXXXXXXX"
assert_eq "restore decrypt staging never follows the carry parent" "$(awk -v p="-d $RS/stage/.restore.XXXXXXXXXX" '$0 != p {print}' "$RS/stage-pattern")" ""
out=$(PITHEAD_RESTORE_CARRY_DIR="$RCARRY" run_sourced "$RS" eval '
    rm() { return 1; }
    clear_restore_carry
' 2>&1)
assert_contains "volatile carry cleanup failure is visible" "$out" 'Could not clear the temporary restore handoff'
assert_not_contains "volatile cleanup warning never reveals the passphrase" "$out" hunter2
printf stage-cleanup-secret >"$RS/setup-secret"
out=$(run_sourced "$RS" eval 'rm() { return 1; }; clear_restore_stage "$RS/volatile/.restore.failed"; clear_setup_candidate "$RS/setup-secret"' 2>&1)
assert_contains "private stage cleanup failure is visible" "$out" 'Could not clear the private restore staging area'
assert_contains "temporary config cleanup failure is visible" "$out" 'Could not clear temporary setup credentials'
assert_not_contains "private cleanup warnings never reveal content" "$out" stage-cleanup-secret
legacy_snapshot=$(wizard_spool_private "$RSPOOL")
printf interrupted-secret >"$legacy_snapshot/value"
rm -rf "$RCARRY" "$RDATA" && clear_restore_submission "$RSPOOL" "$RSECRET" && rm -f "$RSPOOL/applied" "$RCANDIDATE"
printf 'CADDY-ORIG\n' >"$RS/Caddyfile" && printf 'DBDATA-ORIG\n' >"$RS/data/dashboard/dashboard.db" # fixtures back to their case-1 state for the cases below
touch "$RS/.restore-incomplete"
out=$(run_sourced "$RS" firstboot_wizard 2>&1 || echo "rc$?")
assert_contains "first boot refuses an incomplete installed restore" "$out" 'installed restore is incomplete'
assert_eq "first boot sweeps old snapshots before refusing an incomplete restore" "$([ -e "$legacy_snapshot" ] || echo gone)" gone
rm -f "$RS/.restore-incomplete"
OLDROOT="$RS/old-bundle-root"
mkdir -p "$OLDROOT/build/tari" "$OLDROOT/data/tor" "$OLDROOT/data/dashboard" \
    "$OLDROOT/data/monero" "$OLDROOT/data/tari" "$OLDROOT/data/p2pool" "$OLDROOT/bin"
cp "$STACK" "$OLDROOT/pithead"
cp "$ROOT/build/tari/config.toml.template" "$OLDROOT/build/tari/"
cp "$RS/bin/docker" "$RS/bin/sudo" "$OLDROOT/bin/"
cat >"$OLDROOT/.env" <<EOF
MONERO_ONION_ADDRESS=dddddddddddddddddddddddddddddddddddddddddddddddddddddddd.onion
TARI_ONION_ADDRESS=eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee.onion
P2POOL_ONION_ADDRESS=ffffffffffffffffffffffffffffffffffffffffffffffffffffffff.onion
PROXY_AUTH_TOKEN=abcdef0123456789abcdef01
HOST_IP=box.lan
DEPLOYMENT_COMPLETED=true
COMPOSE_PROFILES=local_node
EOF
printf '{ "monero": {"mode":"local","wallet_address":"%s","node_username":"u","node_password":"p"}, "tari":{"wallet_address":"'"$VALID_TARI"'"}, "p2pool":{"pool":"mini"}, "dashboard":{"secure":true,"host":"old-bundle.lan"} }\n' "$WALLET" >"$OLDROOT/config.json"
printf 'CADDY-OLDROOT\n' >"$OLDROOT/Caddyfile"
printf 'ONIONKEY-OLDROOT\n' >"$OLDROOT/data/tor/hs_ed25519_secret_key"
printf 'DBDATA-OLDROOT\n' >"$OLDROOT/data/dashboard/dashboard.db"
printf 'MONERO-CHAIN-OLDROOT\n' >"$OLDROOT/data/monero/lmdb-sentinel"
printf 'TARI-CHAIN-OLDROOT\n' >"$OLDROOT/data/tari/db-sentinel"
printf 'P2POOL-CHAIN-OLDROOT\n' >"$OLDROOT/data/p2pool/db-sentinel"
printf 'MONERO-CHAIN-OLDROOT\n' >"$OLDROOT/data/monero/chain-state"
printf 'TARI-CHAIN-OLDROOT\n' >"$OLDROOT/data/tari/chain-state"
printf 'P2POOL-CHAIN-OLDROOT\n' >"$OLDROOT/data/p2pool/chain-state"
out="$(cd "$OLDROOT" && PATH="$OLDROOT/bin:$PATH" PITHEAD_BACKUP_PASSPHRASE=hunter2 ./pithead backup --with-chains -y 2>&1)"
rc=$?
assert_rc "cross-root fixture: backup exits 0" "$rc" "0"
oldarchive="$(ls "$OLDROOT"/backups/pithead-backup-*.tar.gz.enc 2>/dev/null | head -1)"
{ [ -n "$oldarchive" ] && [ -f "$oldarchive" ]; } && ok "cross-root fixture: encrypted archive created" || bad "cross-root fixture: encrypted archive created" "no .enc archive"
cp "$oldarchive" "$RSPOOL/restore-archive" && printf 'hunter2' >"$RSPOOL/restore-passphrase" # test fixture, not a real secret
mkdir -p "$RS/data/monero" "$RS/data/tari" "$RS/data/p2pool"                                 # the target's chain dirs; only `wipe=keep` leaves them behind, and this fixture is a fresh $RS
printf 'MONERO-CHAIN-TARGET\n' >"$RS/data/monero/chain-state"
printf 'TARI-CHAIN-TARGET\n' >"$RS/data/tari/chain-state"
printf 'P2POOL-CHAIN-TARGET\n' >"$RS/data/p2pool/chain-state"
out="$(cd "$RS" && PATH="$RS/bin:$PATH" run_sourced "$RS" firstboot_consume_restore "$RSPOOL" 2>&1)"
rc=$?
assert_rc "cross-root restore with colliding target chain data returns 0 (#2195)" "$rc" "0"
assert_contains "cross-root restore carries the source box's config" "$(cat "$RS/config.json" 2>/dev/null)" "old-bundle.lan"
assert_eq "cross-root restore brings back the onion key" "$(cat "$RS/data/tor/hs_ed25519_secret_key" 2>/dev/null)" "ONIONKEY-OLDROOT"
assert_eq "cross-root restore brings back the dashboard db" "$(cat "$RS/data/dashboard/dashboard.db" 2>/dev/null)" "DBDATA-OLDROOT"
assert_eq "cross-root restore brings back the monero chain data" "$(cat "$RS/data/monero/lmdb-sentinel" 2>/dev/null)" "MONERO-CHAIN-OLDROOT"
assert_eq "cross-root restore brings back the tari chain data" "$(cat "$RS/data/tari/db-sentinel" 2>/dev/null)" "TARI-CHAIN-OLDROOT"
assert_eq "cross-root restore brings back the p2pool chain data" "$(cat "$RS/data/p2pool/db-sentinel" 2>/dev/null)" "P2POOL-CHAIN-OLDROOT"
assert_eq "target's own monero chain data wins the collision, not resynced from the archive (#2195)" "$(cat "$RS/data/monero/chain-state" 2>/dev/null)" "MONERO-CHAIN-TARGET"
assert_eq "target's own tari chain data wins the collision (#2195)" "$(cat "$RS/data/tari/chain-state" 2>/dev/null)" "TARI-CHAIN-TARGET"
assert_eq "target's own p2pool chain data wins the collision (#2195)" "$(cat "$RS/data/p2pool/chain-state" 2>/dev/null)" "P2POOL-CHAIN-TARGET"
rm -rf "$OLDROOT" "$RS/data/monero" "$RS/data/tari" "$RS/data/p2pool"
rm -f "$RSPOOL/applied" "$RS/config.json"
printf 'CADDY-ORIG\n' >"$RS/Caddyfile" # fixtures back to their case-1 state for the cases below
printf 'DBDATA-ORIG\n' >"$RS/data/dashboard/dashboard.db"
run_sourced "$RS" restore_setup_members "${RS#/}/config.json" "${RS#/}/"
assert_rc "member policy accepts a mapped configuration file" "$?" 0
run_sourced "$RS" restore_setup_members "${RS#/}/data/tor/" "${RS#/}/"
assert_rc "member policy accepts a mapped data directory" "$?" 0
run_sourced "$RS" restore_setup_members "${RS#/}/config.json/" "${RS#/}/"
assert_rc "member policy refuses a directory in place of configuration" "$?" 1
run_sourced "$RS" restore_setup_members "${RS#/}/data/tor" "${RS#/}/"
assert_rc "member policy refuses a file in place of a data directory" "$?" 1
mixed_root_members="${RS#/}/config.json
other/root/data/tor/"
run_sourced "$RS" restore_setup_members "$mixed_root_members" "${RS#/}/"
assert_rc "member policy refuses a member outside the given root" "$?" 1
two_depth_configs="a/config.json
b/config.json"
run_sourced "$RS" restore_setup_root "$two_depth_configs"
assert_rc "root detection refuses config.json at two depths" "$?" 1
PITHEAD_CONFIG_FILE="$RS/config.json" run_sourced "$RS" restore_setup_root "${RS#/}/config.json"
assert_rc "root detection refuses an absolute CONFIG_FILE override" "$?" 1
out=$(PITHEAD_CONFIG_FILE="$RS/config.json" run_sourced "$RS" restore_setup_config_path)
assert_eq "absolute config override is not prefixed with the working directory" "$out" "$RS/config.json"
printf 'one\ntwo\n' >"$RS/restore-names"
printf '%s\n' '-rw------- root/root 4 2026-01-01 00:00 one' '-rw------- root/root 5 2026-01-01 00:00 two' >"$RS/restore-verbose"
run_sourced "$RS" restore_setup_archive_within_limits "$RS/restore-names" "$RS/restore-verbose" 2 9
assert_rc "restore expansion limit accepts its exact bounds" "$?" 0
run_sourced "$RS" restore_setup_archive_within_limits "$RS/restore-names" "$RS/restore-verbose" 1 9
assert_rc "restore expansion limit rejects excess members" "$?" 1
run_sourced "$RS" restore_setup_archive_within_limits "$RS/restore-names" "$RS/restore-verbose" 2 8
assert_rc "restore expansion limit rejects excess bytes" "$?" 1
printf '%s\n' '-rw------- owner with spaces 999999999 2026-01-01 item' >"$RS/restore-verbose"
run_sourced "$RS" restore_setup_archive_within_limits "$RS/restore-names" "$RS/restore-verbose" 2 9
assert_rc "restore expansion limit rejects an ambiguous owner field" "$?" 1
printf publish-secret >"$RS/publish-source"
out=$(run_sourced "$RS" eval 'install() { return 1; }; rm() { return 1; }; restore_setup_publish_file "$RS/publish-source" "$RS/publish-dest"' 2>&1)
assert_contains "failed atomic publication reports cleanup failure" "$out" 'Could not clear temporary setup credentials'
assert_not_contains "failed publication cleanup never reveals content" "$out" publish-secret
mkdir "$RS/list-fixture"
for n in $(seq 1 200); do printf x >"$RS/list-fixture/member-$n-abcdefghijklmnopqrstuvwxyz"; done
tar -czf "$RS/list-fixture.tar.gz" -C "$RS/list-fixture" .
if run_sourced "$RS" restore_setup_tar_list "$RS/list-fixture.tar.gz" -tvzf "$RS/list-output" 1 30; then out=accepted; else out=refused; fi
assert_eq "archive listing is stopped at its output cap" "$out" refused
rm -f "$RS/restore-names" "$RS/restore-verbose"
RPSEED="$RS/preseed"
mkdir "$RPSEED"
cp "$rarchive" "$RPSEED/pithead-restore.enc" && printf hunter2 >"$RPSEED/pithead-restore-pass"
out=$(PITHEAD_PRESEED_DIR="$RPSEED" run_sourced "$RS" eval 'mount() { :; }; mktemp() { case "$*" in -d\ *.restore.*) printf "%s\n" "$*" >"$RS/legacy-stage" ;; esac; command mktemp "$@"; }; consume_preseed_restore && echo rc0')
assert_contains "carried normal backup passes the shared member policy" "$out" rc0
assert_eq "legacy restore decrypt staging uses the volatile root" "$(cat "$RS/legacy-stage")" "-d $RS/stage/.restore.XXXXXXXXXX"
assert_eq "carried backup restores the original database" "$(cat "$RS/data/dashboard/dashboard.db")" DBDATA-ORIG
assert_eq "carried backup consumes its passphrase" "$([ -e "$RPSEED/pithead-restore-pass" ] || echo gone)" gone
cp "$rarchive" "$RPSEED/pithead-restore.enc" && printf hunter2 >"$RPSEED/pithead-restore-pass"
out=$(PITHEAD_PRESEED_DIR="$RPSEED" run_sourced "$RS" eval 'mount() { :; }; rm() { case "$*" in *pithead-restore*) return 1 ;; *) command rm "$@" ;; esac; }; consume_preseed_restore || echo "rc$?"' 2>&1)
assert_contains "successful carry cleanup failure is fatal" "$out" rc3
assert_contains "successful carry cleanup failure follows archive application" "$(cat "$RS/config.json" 2>/dev/null)" "$WALLET"
assert_contains "successful carry cleanup failure is visible" "$out" 'Could not remove every consumed restore carry file'
assert_not_contains "successful carry cleanup warning hides the passphrase" "$out" hunter2
rm -f "$RPSEED/pithead-restore.enc" "$RPSEED/pithead-restore-pass"
cp "$rarchive" "$RPSEED/pithead-restore.enc" && printf hunter2 >"$RPSEED/pithead-restore-pass" && rm -f "$RS/config.json"
out=$(PITHEAD_PRESEED_DIR="$RPSEED" run_sourced "$RS" eval 'mount() { :; }; clear_restore_stage() { warn "Could not clear the private restore staging area."; return 1; }; consume_preseed_restore || echo "rc$?"' 2>&1)
assert_contains "legacy applied-stage cleanup failure is fatal" "$out" rc3
assert_contains "legacy cleanup failure follows archive application" "$(cat "$RS/config.json" 2>/dev/null)" "$WALLET"
assert_contains "legacy stage cleanup failure is visible" "$out" 'reboot before continuing'
assert_not_contains "legacy stage cleanup warning hides the passphrase" "$out" hunter2
printf orphan-secret >"$RPSEED/pithead-restore-pass"
out=$(PITHEAD_PRESEED_DIR="$RPSEED" run_sourced "$RS" eval 'mount() { :; }; consume_preseed_restore || echo "rc$?"' 2>&1)
assert_contains "an orphan legacy passphrase is reported generically" "$out" 'incomplete legacy restore handoff was cleared'
assert_not_contains "the orphan cleanup report never reveals the passphrase" "$out" orphan-secret
assert_eq "an orphan legacy passphrase is consumed" "$([ -e "$RPSEED/pithead-restore-pass" ] || echo gone)" gone
printf orphan-failure-secret >"$RPSEED/pithead-restore-pass"
out=$(PITHEAD_PRESEED_DIR="$RPSEED" run_sourced "$RS" eval 'mount() { :; }; rm() { return 1; }; consume_preseed_restore || echo "rc$?"' 2>&1)
assert_contains "orphan cleanup failure is visible" "$out" 'Could not clear an incomplete legacy restore handoff'
assert_contains "orphan cleanup failure is fatal" "$out" rc3
assert_not_contains "orphan cleanup failure does not claim success" "$out" 'was cleared'
assert_not_contains "orphan cleanup failure never reveals the passphrase" "$out" orphan-failure-secret
rm -f "$RPSEED/pithead-restore-pass"
chmod 644 "$RS/data/dashboard/dashboard.db"
tar -czf "$RS/hostile-live.tar.gz" -C / "${RS#/}/config.json" "${RS#/}/data/dashboard/dashboard.db"
printf sentinel >"$RS/outside-target"
rm "$RS/data/dashboard/dashboard.db"
ln -s "$RS/outside-target" "$RS/data/dashboard/dashboard.db"
run_sourced "$RS" restore_apply "$RS/hostile-live.tar.gz" '' "$RS/restore-error"
assert_rc "restore safely replaces a planted destination symlink" "$?" 0
assert_eq "restore leaves the planted symlink target untouched" "$(cat "$RS/outside-target")" sentinel
assert_eq "restored database is a regular file" "$([ -f "$RS/data/dashboard/dashboard.db" ] && [ ! -L "$RS/data/dashboard/dashboard.db" ] && echo yes)" yes
assert_eq "restored database permissions are private" "$(stat -c '%a' "$RS/data/dashboard/dashboard.db")" 600
printf 'ordinary note' >"$RS/unexpected.txt"
printf 'BACKUP-CADDY' >"$RS/Caddyfile"
tar -czf "$RS/unexpected.tar.gz" -C / "${RS#/}/config.json" "${RS#/}/.env" "${RS#/}/Caddyfile" "${RS#/}/unexpected.txt"
printf 'CADDY-ORIG\n' >"$RS/Caddyfile"
rm -f "$RS/config.json"
cp "$RS/unexpected.tar.gz" "$RSPOOL/restore-archive"
out=$(run_sourced "$RS" firstboot_consume_restore "$RSPOOL" 1 || echo "rc$?")
assert_contains "wizard refuses an unexpected regular backup member" "$out" rc1
assert_contains "member refusal identifies the backup layout" "$(cat "$RSPOOL/error.txt")" 'outside the appliance backup layout'
assert_eq "invalid wizard backup does not surface a config" "$([ -e "$RS/config.json" ] || echo gone)" gone
assert_eq "invalid wizard backup is not staged for installation" "$([ -e "$RCARRY/archive" ] || echo gone)" gone
cp "$RS/unexpected.tar.gz" "$RPSEED/pithead-restore.enc" && printf '' >"$RPSEED/pithead-restore-pass"
out=$(PITHEAD_PRESEED_DIR="$RPSEED" run_sourced "$RS" eval 'mount() { :; }; consume_preseed_restore || echo "rc$?"' 2>&1)
assert_contains "carried backup refuses an unexpected regular member" "$out" rc1
assert_contains "carried member refusal identifies the backup layout" "$out" 'outside the appliance backup layout'
assert_eq "member refusal applies no valid files beside the invalid member" "$(cat "$RS/Caddyfile")" CADDY-ORIG
assert_eq "rejected carried backup is consumed" "$([ -e "$RPSEED/pithead-restore.enc" ] || echo gone)" gone
cp "$RS/unexpected.tar.gz" "$RPSEED/pithead-restore.enc" && printf 'failure-cleanup-secret' >"$RPSEED/pithead-restore-pass"
out=$(PITHEAD_PRESEED_DIR="$RPSEED" run_sourced "$RS" eval '
    mount() { :; }
    rm() { case "$*" in *pithead-restore*) return 1 ;; *) command rm "$@" ;; esac; }
    consume_preseed_restore || echo "rc$?"; clear_legacy_restore_carry "$RPSEED" || true
' 2>&1)
assert_contains "rejected carry cleanup failure is visible" "$out" 'Could not remove every rejected restore carry file'
assert_contains "rejected carry cleanup failure is fatal" "$out" rc3
assert_contains "legacy handoff cleanup failure is visible" "$out" 'Could not clear every legacy restore handoff file'
assert_not_contains "cleanup warning never reveals the passphrase" "$out" 'failure-cleanup-secret'
rm -f "$RPSEED/pithead-restore.enc" "$RPSEED/pithead-restore-pass"
rm -f "$RSPOOL/error.txt"
cp "$rarchive" "$RSPOOL/restore-archive" && printf hunter2 >"$RSPOOL/restore-passphrase" && rm -f "$RS/config.json"
out=$(run_sourced "$RS" eval 'clear_restore_stage() { warn "Could not clear the private restore staging area."; return 1; }; firstboot_consume_restore "$RSPOOL" || echo "rc$?"' 2>&1)
assert_contains "direct applied-stage cleanup failure is fatal" "$out" rc3
assert_contains "direct stage cleanup failure follows archive application" "$(cat "$RS/config.json" 2>/dev/null)" "$WALLET"
assert_contains "direct stage cleanup failure reaches the page" "$(cat "$RSPOOL/error.txt")" 'could not clear private restore staging safely'
assert_not_contains "direct stage cleanup warning hides the passphrase" "$out" hunter2
assert_eq "direct stage cleanup publishes no success state" "$(find "$RSPOOL" -maxdepth 1 \( -name applied -o -name restore-inflight \) -print)" ""
rm -f "$RSPOOL/error.txt" "$RS/config.json"
cp "$rarchive" "$RSPOOL/restore-archive" && printf hunter2 >"$RSPOOL/restore-passphrase"
out=$(run_sourced "$RS" eval 'wizard_spool_clean_checked() { return 1; }; firstboot_consume_restore "$RSPOOL" || echo "rc$?"' 2>&1)
assert_contains "accepted restore cleanup failure is fatal" "$out" rc3
assert_contains "cleanup failure follows an accepted restore" "$(cat "$RS/config.json" 2>/dev/null)" "$WALLET"
assert_contains "accepted restore cleanup failure is visible" "$out" 'Could not clear every private restore snapshot'
assert_contains "accepted restore cleanup failure reaches the page" "$(cat "$RSPOOL/error.txt")" 'Could not clear private restore files safely'
assert_not_contains "accepted cleanup warning never reveals the passphrase" "$out" hunter2
assert_eq "accepted cleanup failure publishes no success state" "$(find "$RSPOOL" -maxdepth 1 \( -name applied -o -name restore-inflight \) -print)" ""
rm -rf "$RSPOOL"/.host.* && rm -f "$RSPOOL/error.txt" "$RS/config.json"
printf 'CORRUPTED\n' >"$RS/Caddyfile"
cp "$rarchive" "$RSPOOL/restore-archive" && printf 'not-the-passphrase' >"$RSPOOL/restore-passphrase" # test fixture
out=$(run_sourced "$RS" eval 'wizard_spool_clean_checked() { return 1; }; firstboot_consume_restore "$RSPOOL" || echo "rc$?"' 2>&1)
assert_contains "wrong passphrase rejected" "$out" "rc1"
assert_contains "private snapshot cleanup failure is visible" "$out" 'Could not clear every private restore snapshot'
assert_not_contains "private cleanup warning never reveals submitted content" "$out" not-the-passphrase
assert_contains "wrong passphrase names the cause" "$(cat "$RSPOOL/error.txt" 2>/dev/null)" "assphrase"
assert_eq "wrong passphrase leaves live files untouched" "$(cat "$RS/Caddyfile")" "CORRUPTED"
assert_eq "the archive is consumed even on rejection" "$([ -f "$RSPOOL/restore-archive" ] || echo gone)" "gone"
assert_eq "the passphrase is never retained even on rejection" "$([ -f "$RSPOOL/restore-passphrase" ] || echo gone)" "gone"
printf 'CADDY-ORIG\n' >"$RS/Caddyfile"
rm -f "$RSPOOL/error.txt"
printf 'snapshot-failure-secret' >"$RSPOOL/failed-pass"
out=$(run_sourced "$RS" eval 'wizard_spool_clean_checked() { return 1; }; head() { return 1; }; wizard_spool_snapshot "$RSPOOL" failed-pass || true' 2>&1)
assert_contains "failed private snapshot cleanup is visible" "$out" 'Could not clear a failed private wizard snapshot'
assert_not_contains "failed private snapshot cleanup never reveals content" "$out" snapshot-failure-secret
cp "$rarchive" "$RSPOOL/restore-archive"
out=$(run_sourced "$RS" firstboot_consume_restore "$RSPOOL" || echo "rc$?")
assert_contains "missing passphrase rejected" "$out" "rc1"
assert_contains "missing passphrase names the cause" "$(cat "$RSPOOL/error.txt" 2>/dev/null)" "passphrase"
rm -f "$RSPOOL/error.txt"
truncate -s 67108865 "$RSPOOL/restore-archive"
printf 'hunter2' >"$RSPOOL/restore-passphrase" # test fixture
out=$(run_sourced "$RS" firstboot_consume_restore "$RSPOOL" || echo "rc$?")
assert_contains "oversize archive rejected" "$out" "rc1"
assert_contains "oversize archive names the cap" "$(cat "$RSPOOL/error.txt" 2>/dev/null)" "too large"
rm -f "$RSPOOL/error.txt"
printf 'garbage-not-an-archive' >"$RSPOOL/restore-archive"
printf 'hunter2' >"$RSPOOL/restore-passphrase" # test fixture
out=$(run_sourced "$RS" firstboot_consume_restore "$RSPOOL" || echo "rc$?")
assert_contains "malformed archive rejected" "$out" "rc1"
assert_contains "malformed archive names the problem" "$(cat "$RSPOOL/error.txt" 2>/dev/null)" "not a Pithead backup archive"
assert_eq "malformed archive leaves config.json untouched" "$([ -f "$RS/config.json" ] || echo gone)" "gone"
rm -f "$RSPOOL/error.txt"
MAL="$RS/mal"
mkdir -p "$MAL/pithead"
printf 'CADDY-ORIG\n' >"$RS/Caddyfile"     # live file the escape would try to clobber via symlink
ln -s /etc/shadow "$MAL/pithead/Caddyfile" # symlink escape
(cd "$MAL" && tar -czf "$RSPOOL/restore-archive" pithead) 2>/dev/null
out=$(run_sourced "$RS" firstboot_consume_restore "$RSPOOL" || echo "rc$?")
assert_contains "a symlink member is refused" "$out" "rc1"
assert_contains "the symlink refusal names the cause" "$(cat "$RSPOOL/error.txt" 2>/dev/null)" "unsafe paths or links"
assert_eq "a symlink archive touches nothing" "$(cat "$RS/Caddyfile")" "CADDY-ORIG"
rm -f "$RSPOOL/error.txt" "$RSPOOL/restore-passphrase"
printf 'EVIL\n' >"$MAL/evil"
(cd "$MAL" && tar -Pczf "$RSPOOL/restore-archive" "$MAL/evil") 2>/dev/null
out=$(run_sourced "$RS" firstboot_consume_restore "$RSPOOL" || echo "rc$?")
assert_contains "an absolute-path member is refused" "$out" "rc1"
rm -f "$RSPOOL/error.txt"
out=$(run_sourced "$RS" firstboot_consume_restore "$RSPOOL" || echo "rc$?")
assert_contains "empty spool is rc2" "$out" "rc2"
rm -rf "$RS"
