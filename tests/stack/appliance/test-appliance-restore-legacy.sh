# shellcheck shell=bash
# shellcheck disable=SC2154 # test-appliance-restore.sh sets $rarchive before run.sh sources this file.
: "${STACK_SUITE:?is unset: this file is a tests/stack/run.sh fragment, not a script — run tests/stack/run.sh}"

# Continued from test-appliance-restore.sh on its fixture ($RS, $rarchive, $WALLET); $RPSEED is set
# here and reused by test-appliance-restore-publish.sh.
echo "== unit: consume_preseed_restore — the legacy carried-ESP door (#1854, #2626) =="
# The legacy carried-ESP door: a target an older installer wrote may still hold the archive and
# its passphrase on the ESP. First boot consumes that pair and scrubs it, accepted or not.
RPSEED="$RS/preseed"
mkdir "$RPSEED"
cp "$rarchive" "$RPSEED/pithead-restore.enc" && printf hunter2 >"$RPSEED/pithead-restore-pass"
rm -f "$RS/data/dashboard/sync-gate-reset"
out=$(PITHEAD_PRESEED_DIR="$RPSEED" run_sourced "$RS" eval 'mount() { :; }; mktemp() { case "$*" in -d\ */.restore.*) printf "%s\n" "$*" >"$RS/legacy-stage" ;; esac; command mktemp "$@"; }; consume_preseed_restore && echo rc0')
assert_contains "carried normal backup passes the shared member policy" "$out" rc0
assert_eq "legacy restore decrypt staging uses the volatile root" "$(cat "$RS/legacy-stage")" "-d $RS/stage/.restore.XXXXXXXXXX"
assert_eq "carried backup restores the original database" "$(cat "$RS/data/dashboard/dashboard.db")" DBDATA-ORIG
assert_eq "carried backup marks the sync gate for re-derivation (#2626)" "$([ -f "$RS/data/dashboard/sync-gate-reset" ] && echo yes)" yes
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
