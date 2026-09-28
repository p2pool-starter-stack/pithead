# shellcheck shell=bash
# shellcheck disable=SC2154 # test-appliance-restore.sh sets $rarchive before run.sh sources this file.
: "${STACK_SUITE:?is unset: this file is a tests/stack/run.sh fragment, not a script — run tests/stack/run.sh}"

# restore_apply's publication, continued from test-appliance-restore.sh on its fixture ($RS, $RSPOOL,
# $RCARRY, $RPSEED, $rarchive): hostile live links and archive modes, removed 1.x keys, unexpected
# members refused by every door, and accepted restores whose private cleanup fails (rc 3).
echo "== unit: restore_apply publication — links, modes, 1.x keys, members, failed cleanup (#909, #1854) =="
# Restore publication replaces hostile live links and clamps archive-provided modes.
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
# A 1.x backup's removed keys migrate while restore stages it (#2001): xmrig_proxy.* moves to xvb.*
# and telegram.control is dropped, and the staging sweep leaves no .bak-1x on the live side (#1845).
RL="$RS/legacy-1x"
mkdir -p "$RL/${RS#/}"
cp "$RS/config.json" "$RL/live-config.json"
cp "$RS/.env" "$RL/live.env"
jq '.xmrig_proxy = {enabled: true, url: "eu.xmrvsbeast.com:4247", donor_id: "legacy-donor"} | .telegram = {control: {enabled: false}} | del(.xvb)' \
    "$RS/config.json" >"$RL/${RS#/}/config.json"
tar -czf "$RL/archive.tar.gz" -C "$RL" "${RS#/}/config.json"
PATH="$RS/bin:$PATH" run_sourced "$RS" restore_apply "$RL/archive.tar.gz" '' "$RS/restore-error"
assert_rc "restore accepts a backup carrying removed 1.x keys" "$?" 0
assert_eq "restore moves xmrig_proxy.* to xvb.* unchanged" "$(jq -c '[has("xmrig_proxy"), .xvb.enabled, .xvb.url, .xvb.donor_id]' "$RS/config.json")" '[false,true,"eu.xmrvsbeast.com:4247","legacy-donor"]'
assert_eq "restore drops the removed telegram.control" "$(jq -c '.telegram | has("control")' "$RS/config.json")" false
assert_eq "restore renders the migrated XvB settings" "$(grep -E '^XVB_(POOL_URL|DONOR_ID)=' "$RS/.env" | sort | tr '\n' ' ')" "XVB_DONOR_ID=legacy-donor XVB_POOL_URL=eu.xmrvsbeast.com:4247 "
assert_eq "restore leaves no pre-migration .bak-1x beside the config" "$(find "$RS" -maxdepth 1 -name '*.bak-1x' -print -quit)" ""
cp "$RL/live-config.json" "$RS/config.json"
cp "$RL/live.env" "$RS/.env"
rm -rf "$RL"
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

# An accepted restore whose private staging or snapshots cannot be cleared is rc 3: its config
# already landed, but no success state is published and the host stops the boot.
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
