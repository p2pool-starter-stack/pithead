# shellcheck shell=bash
: "${STACK_SUITE:?is unset: this file is a tests/stack/run.sh fragment, not a script — run tests/stack/run.sh}"
# One boundary suite: private creation, hostile directory entries, immutable consumption and
# the mixed ownership needed by the page's retry protocol. Full boot remains a KVM gate.
echo "== unit: wizard spool publication and snapshot boundary =="
mk_tmpdir WSS
mkdir "$WSS/spool"
printf sentinel >"$WSS/target"
ln -s "$WSS/target" "$WSS/spool/error.txt"
run_sourced "$WSS" wizard_spool_publish "$WSS/spool" error.txt printf '%s' fixture-secret
assert_rc "a planted output symlink is replaced atomically" "$?" 0
assert_eq "the output symlink target stays untouched" "$(cat "$WSS/target")" sentinel
assert_eq "the published error is private" "$(stat -c '%a' "$WSS/spool/error.txt")" 600
assert_eq "the page gets the error" "$(cat "$WSS/spool/error.txt")" fixture-secret
run_sourced "$WSS" eval 'producer() { [ "$(stat -Lc %a /proc/$BASHPID/fd/1)" = 600 ] || return 1; printf first-byte; }; umask 000; wizard_spool_publish "$WSS/spool" last-attempt.json producer'
assert_rc "the output inode is 600 before the first secret byte" "$?" 0
assert_eq "a successful producer is published" "$(cat "$WSS/spool/last-attempt.json")" first-byte
run_sourced "$WSS" eval 'producer() { printf partial; return 1; }; wizard_spool_publish "$WSS/spool" last-attempt.json producer'
assert_rc "a failed producer refuses publication" "$?" 1
assert_eq "producer failure keeps the previous complete output" "$(cat "$WSS/spool/last-attempt.json")" first-byte
for kind in symlink fifo directory hardlink; do
    case "$kind" in
    symlink) ln -s "$WSS/target" "$WSS/spool/request" ;;
    fifo) mkfifo "$WSS/spool/request" ;;
    directory) mkdir "$WSS/spool/request" ;;
    hardlink) ln "$WSS/target" "$WSS/spool/request" ;;
    esac
    run_sourced "$WSS" wizard_spool_read "$WSS/spool" request >/dev/null 2>&1
    assert_rc "unsafe input is refused without reading it" "$?" 1
    if [ "$kind" = directory ]; then rmdir "$WSS/spool/request"; else rm -f "$WSS/spool/request"; fi
done
printf original >"$WSS/spool/request"
SNAP=$(run_sourced "$WSS" wizard_spool_snapshot "$WSS/spool" request)
printf replacement >"$WSS/spool/request"
assert_eq "in-place page writes cannot change a completed snapshot" "$(cat "$SNAP")" original
run_sourced "$WSS" wizard_spool_clean "${SNAP%/*}"
run_sourced "$WSS" wizard_spool_snapshot "$WSS/spool" request 2 >/dev/null
assert_rc "oversize requests have a distinct refusal status" "$?" 3
run_sourced "$WSS" eval 'ln() { command ln "$@"; rm -f "$WSS/spool/request"; command ln -s "$WSS/target" "$WSS/spool/request"; }; wizard_spool_read "$WSS/spool" request' >/dev/null
assert_rc "replacement during pinning fails closed" "$?" 1
assert_eq "replacement target is unchanged" "$(cat "$WSS/target")" sentinel
rm -f "$WSS/spool/request"
touch "$WSS/spool/submission-staging"
printf '{}' >"$WSS/spool/config.json"
printf '{}' >"$WSS/spool/rig-request.json"
printf archive >"$WSS/spool/restore-archive"
for consumer in 'firstboot_consume_spool "$WSS/spool"' 'firstboot_consume_rig "$WSS/spool"' 'firstboot_consume_restore "$WSS/spool"'; do
    run_sourced "$WSS" eval "$consumer" >/dev/null 2>&1
    assert_rc "a partial generation is not consumed" "$?" 2
done
assert_eq "partial triggers remain for startup cleanup" "$(find "$WSS/spool" -maxdepth 1 \( -name config.json -o -name rig-request.json -o -name restore-archive \) | wc -l | tr -d ' ')" 3
run_sourced "$WSS" wizard_clear_submission_transaction "$WSS/spool"
assert_rc "startup clears a partial transaction" "$?" 0
assert_eq "startup clears a partial config trigger" "$([ -e "$WSS/spool/config.json" ] || echo gone)" gone
rm -f "$WSS/spool/rig-request.json" "$WSS/spool/restore-archive"
# Caller proof: the dial occurs between parsing and promotion. Change the original request at
# that point; every field that lands must still come from the private snapshot.
printf '{"pool":"example.test:3333","worker":"original","stratum_password":"fixture"}' >"$WSS/spool/rig-request.json"
run_sourced "$WSS" eval 'timeout() { printf "{}" >"$WSS/spool/rig-request.json"; }; firstboot_consume_rig "$WSS/spool"' >/dev/null
assert_rc "normal rig acceptance uses a snapshot" "$?" 0
assert_eq "request replacement cannot alter accepted worker/password" "$(jq -c '[.worker,.stratum_password]' "$WSS/rig.json")" '["original","fixture"]'
printf '{"fixture":true}' >"$WSS/spool/config.json"
run_sourced "$WSS" eval 'bash() { printf "{}" >"$WSS/spool/config.json"; }; firstboot_consume_spool "$WSS/spool"' >/dev/null
assert_rc "config acceptance promotes the validated snapshot" "$?" 0
assert_eq "the promoted config is the snapshot, not the replaced request" "$(jq -c . "$WSS/config.json")" '{"fixture":true}'
assert_eq "accepted config is private" "$(stat -c '%a' "$WSS/config.json")" 600
mkdir -p "$WSS/outside/.host.fixture"
printf sentinel >"$WSS/outside/.host.fixture/value"
ln -s "$WSS/outside" "$WSS/spool-link"
run_sourced "$WSS" clear_legacy_wizard_snapshots "$WSS/spool-link"
assert_rc "legacy cleanup rejects a symlinked spool" "$?" 1
assert_eq "a symlinked spool cannot redirect cleanup" "$(cat "$WSS/outside/.host.fixture/value")" sentinel
mkdir -p "$WSS/restart-stage/.restore.crash" "$WSS/restart-carry" "$WSS/restart-submit/.host.crash"
printf stage-secret >"$WSS/restart-stage/.restore.crash/value"
printf carry-secret >"$WSS/restart-carry/pass"
printf snapshot-secret >"$WSS/restart-submit/.host.crash/value"
run_sourced "$WSS" clear_restore_stages "$WSS/restart-stage"
assert_rc "restart clears crash-left decrypted stages" "$?" 0
run_sourced "$WSS" clear_restore_carry "$WSS/restart-carry"
assert_rc "restart clears crash-left restore carry" "$?" 0
run_sourced "$WSS" clear_legacy_wizard_snapshots "$WSS/restart-submit"
assert_rc "restart clears crash-left private snapshots" "$?" 0
assert_eq "restart leaves no plaintext restore artifacts" "$(find "$WSS" -name '*-secret' -o -name '.restore.crash' -o -name '.host.crash')" ""
mkdir -p "$WSS/restart-outside"
printf cleanup-secret >"$WSS/restart-outside/value"
ln -s "$WSS/restart-outside" "$WSS/restart-stage/.restore.escape"
out=$(run_sourced "$WSS" clear_restore_stages "$WSS/restart-stage" 2>&1)
assert_rc "restart refuses a redirected restore stage" "$?" 1
assert_contains "restore-stage cleanup failure is visible" "$out" 'Could not clear temporary restore staging safely'
assert_not_contains "restore-stage cleanup failure hides content" "$out" cleanup-secret
assert_eq "restore-stage cleanup never follows a symlink" "$(cat "$WSS/restart-outside/value")" cleanup-secret
rm -f "$WSS/restart-stage/.restore.escape"

mk_tmpdir WBK
mkdir -p "$WBK/preseed"
WBK_STUBS='machine_role() { echo pithead; }; setup_again_mode() { return 1; }
installer_mode_available() { return 1; }; consume_preseed_restore() { return 1; }; consume_preseed_config() { return 2; }
boot_is_removable() { return 1; }; _console() { :; }; container_engine() { echo true; }
export_build_provenance() { PITHEAD_REGISTRY=fixture; STACK_VERSION=dev; }; load_baked_images() { :; }
stage_wizard_spool() { mkdir -p "$1"; echo fingerprint; }; preseed_token() { echo pit-fixture; }
wizard_keep_requested() { return 1; }; wizard_spool_has() { return 1; }; firstboot_consume_rig() { return 2; }
firstboot_consume_restore() { return 2; }; firstboot_consume_spool() { printf "{}" >config.json; return 0; }
preflight_remote_nodes() { :; }; ensure_appliance_dashboard_password() { :; }; apply_appliance_defaults() { :; }
wizard_spool_publish() { :; }; warn() { :; }; log() { :; }; bash() { cp config.json config.json.bak-1x; return 1; }
sleep() { exit 7; }'
PITHEAD_PRESEED_DIR="$WBK/preseed" run_sourced "$WBK" eval "$WBK_STUBS; firstboot_wizard" >/dev/null 2>&1
assert_rc "post-validation refusal reaches candidate cleanup" "$?" 7
assert_eq "post-validation refusal leaves no migration backup" "$([ -e "$WBK/config.json.bak-1x" ] || echo gone)" gone
mkdir -p "$WBK/installed/preseed" "$WBK/installed/data/firstboot"
printf live-config-sentinel >"$WBK/installed/config.json"
touch "$WBK/installed/data/firstboot/submission-active"
WBR_STUBS="$WBK_STUBS
setup_again_mode() { return 0; }
firstboot_consume_restore() { touch data/firstboot/submission-active; return 1; }"
PITHEAD_PRESEED_DIR="$WBK/installed/preseed" run_sourced "$WBK/installed" eval "$WBR_STUBS; firstboot_wizard" >/dev/null 2>&1
assert_rc "installed-machine rejected restore returns to the form" "$?" 7
assert_eq "installed-machine rejected restore preserves the live config" "$(cat "$WBK/installed/config.json")" live-config-sentinel
assert_eq "rejected restore releases its submission transaction" "$([ -e "$WBK/installed/data/firstboot/submission-active" ] || echo gone)" gone
WBF_STUBS="$WBK_STUBS
setup_again_mode() { return 0; }
firstboot_consume_restore() { return 3; }
error() { exit 11; }"
PITHEAD_PRESEED_DIR="$WBK/installed/preseed" run_sourced "$WBK/installed" eval "$WBF_STUBS; firstboot_wizard" >/dev/null 2>&1
assert_rc "accepted restore cleanup failure stops the wizard" "$?" 11
WBP_STUBS="$WBK_STUBS
consume_preseed_restore() { return 3; }
error() { exit 12; }"
PITHEAD_PRESEED_DIR="$WBK/preseed" run_sourced "$WBK" eval "$WBP_STUBS; firstboot_wizard" >/dev/null 2>&1
assert_rc "legacy applied-stage cleanup failure stops first boot" "$?" 12
rm -rf "$WBK"
unset WBK WBK_STUBS WBR_STUBS WBF_STUBS WBP_STUBS
mk_tmpdir WRS
mkdir -p "$WRS/data/firstboot" "$WRS/restore" "$WRS/carry" "$WRS/preseed"
printf '{}' >"$WRS/config.json"
printf plaintext-secret >"$WRS/restore/restore-archive"
printf passphrase-secret >"$WRS/restore/restore-passphrase"
printf candidate-secret >"$WRS/restore/config.json"
printf card-secret >"$WRS/restore/handoff.json"
printf carry-secret >"$WRS/carry/pass"
WRS_STUBS='machine_role() { echo pithead; }; setup_again_mode() { return 1; }
installer_mode_available() { return 1; }; consume_preseed_restore() { return 1; }
consume_preseed_config() { return 2; }; ensure_appliance_dashboard_password() { :; }
apply_appliance_defaults() { :; }; record_machine_role() { :; }
setup() { [ ! -e "$WRS/restore/restore-archive" ] && [ ! -e "$WRS/restore/restore-passphrase" ] && [ ! -e "$WRS/restore/config.json" ] && [ ! -e "$WRS/restore/handoff.json" ] && [ ! -e "$WRS/carry" ] || exit 9; exit 7; }
firstboot_wizard'
PITHEAD_PRESEED_DIR="$WRS/preseed" PITHEAD_RESTORE_SUBMISSION_DIR="$WRS/restore" \
    PITHEAD_RESTORE_CARRY_DIR="$WRS/carry" run_sourced "$WRS" eval "$WRS_STUBS" >/dev/null 2>&1
assert_rc "restart clears restore secrets before an existing-config early return" "$?" 7
rm -rf "$WRS"
unset WRS WRS_STUBS
printf '{"monero":{"wallet_address":"4retry","node_password":"restore-secret"},"dashboard":{"auth":{"password":"restore-secret"}},"notifications":{"token":"restore-secret"}}' >"$WSS/candidate.json"
run_sourced "$WSS" eval 'installer_mode_available() { return 1; }; wizard_publish_retry_config "$WSS/spool" "$WSS/candidate.json" 1'
assert_rc "installer retry publication uses the latched session mode" "$?" 0
assert_contains "installer retry keeps non-secret answers" "$(cat "$WSS/spool/last-attempt.json")" 4retry
assert_not_contains "installer retry persists no restored credential" "$(cat "$WSS/spool/last-attempt.json")" restore-secret
mkdir -p "$WSS/carry"
touch "$WSS/spool/restore-inflight" "$WSS/carry/pass"
run_sourced "$WSS" wizard_clear_restore_state 0 "$WSS/spool" "$WSS/spool" "$WSS/carry"
assert_rc "abandoned restore cleanup succeeds" "$?" 0
assert_eq "abandoned restore clears its in-flight marker" "$([ -e "$WSS/spool/restore-inflight" ] || echo gone)" gone
assert_eq "abandoned restore clears its volatile carry" "$([ -e "$WSS/carry" ] || echo gone)" gone
run_sourced "$WSS" eval 'install() { return 99; }; rm() { return 99; }; wizard_restore_installer_preseeds "" 0'
assert_rc "restore cleanup leaves installer pre-seeds untouched" "$?" 0
run_sourced "$WSS" eval 'wizard_restore_installer_preseeds() { :; }; clear_setup_candidate() { :; }; clear_legacy_restore_carry() { return 1; }; wizard_clear_restore_state() { :; }; wizard_cleanup_installer_credentials a b c 0 d e f'
assert_rc "legacy credential cleanup failure stops installer cleanup" "$?" 1
fb_restore_paths=$(sed -n '/^firstboot_wizard() {/,/^}$/p' "$STACK")
assert_eq "every retry snapshot uses the secret-stripping publisher" "$(grep -c wizard_publish_retry_config <<<"$fb_restore_paths")" 3
assert_eq "every accepted-restore exit clears its marker and carry" "$(grep -c 'wizard_clear_restore_state "$rec"' <<<"$fb_restore_paths")" 5
assert_eq "both installer exits check the shared credential cleanup" "$(grep -c wizard_cleanup_installer_credentials <<<"$fb_restore_paths")" 2
assert_contains "bare keep waits for the final ready marker" "$fb_restore_paths" 'wizard_submission_ready "$spool"'
assert_contains "bare keep also waits for the volatile archive to be absent" "$fb_restore_paths" '$restore_spool/restore-archive'
assert_contains "restart cleanup sweeps decrypted restore stages" "$fb_restore_paths" 'clear_restore_stages'
assert_contains "restart cleanup clears restore submissions before early returns" "$fb_restore_paths" 'wizard_clear_restore_state 0'
assert_contains "multipart uploads spool only in volatile storage" "$fb_restore_paths" 'TMPDIR=/wizard-restore'
unset fb_restore_paths
echo "== unit: wizard submission policy and reusable-media lifecycle =="
# Invalid host syntax is rejected before any network command is constructed. The timeout stub
# succeeding is a control: the old format-only predicate would accept this request.
printf '{"pool":"invalid host:3333","worker":"fixture"}' >"$WSS/spool/rig-request.json"
run_sourced "$WSS" eval 'timeout() { : >"$WSS/dialed"; return 0; }; firstboot_consume_rig "$WSS/spool"' >/dev/null
assert_rc "invalid rig host syntax is refused before the dial" "$?" 1
[ ! -e "$WSS/dialed" ] && ok "invalid host never reaches the network command" || bad "invalid host never reaches the network command" "dialed"
printf '{"pool":"example.test:3333","worker":"fixture"}' >"$WSS/spool/rig-request.json"
run_sourced "$WSS" eval 'timeout() { [ "$#" = 7 ] && [ "$5" = _ ] && [ "$6" = example.test ] && [ "$7" = 3333 ]; }; firstboot_consume_rig "$WSS/spool"' >/dev/null
assert_rc "rig host and port travel as command arguments" "$?" 0
# A keep-only request cannot turn into a wipe after the shortcut's readiness check.
printf 'disk-fixture\tall' >"$WSS/spool/install-request"
run_sourced "$WSS" eval 'install_bin() { : >"$WSS/installer-called"; echo /nonexistent; }; consume_install_request "$WSS/spool" keep' >/dev/null
assert_rc "the keep-only consumer refuses a replaced wipe request" "$?" 1
[ ! -e "$WSS/installer-called" ] && ok "keep-only refusal happens before invoking the installer" || bad "keep-only refusal happens before invoking the installer" "called"
assert_contains "keep-only refusal returns an editable error" "$(cat "$WSS/spool/error.txt")" 'request changed'
# The reader rejects over-limit input before restore_apply; the passphrase still belongs to the
# rejected attempt and must be consumed on that early return.
truncate -s 67108865 "$WSS/spool/restore-archive"
printf fixture-pass >"$WSS/spool/restore-passphrase"
run_sourced "$WSS" firstboot_consume_restore "$WSS/spool" >/dev/null
assert_rc "oversize restore is rejected" "$?" 1
assert_contains "oversize restore names the problem" "$(cat "$WSS/spool/error.txt")" 'too large'
[ ! -e "$WSS/spool/restore-passphrase" ] && ok "early archive rejection consumes its passphrase" || bad "early archive rejection consumes its passphrase" "retained"
# Run the actual new-machine path until image loading, before a page or container starts.
# Its stubbed inventory selects installer mode; no disk, network or container is touched.
mkdir "$WSS/preseed"
WS_NEW_MACHINE='
    _console() { :; }; container_engine() { echo fixture-engine; }
    installer_mode_available() { return 0; }; machine_role() { echo pithead; }
    export_build_provenance() { STACK_VERSION=fixture; PITHEAD_REGISTRY=registry.example; }
    stage_wizard_spool() { :; }; prefill_from_previous_install() { return 1; }
    load_baked_images() { exit 7; }; firstboot_wizard
'
for ws_file in last-attempt.json install-attempt.json auth-mode config-changes.json setup-failed submission-staging; do
    printf old-machine >"$WSS/spool/$ws_file"
done
printf partial-config >"$WSS/spool/config.json"
# firstboot's canonical spool is data/firstboot; retain the same inode for the fixture.
mkdir "$WSS/data"
mv "$WSS/spool" "$WSS/data/firstboot"
PITHEAD_PRESEED_DIR="$WSS/preseed" run_sourced "$WSS" eval "$WS_NEW_MACHINE" >/dev/null 2>&1
assert_rc "new machine reaches the image-loading boundary" "$?" 7
WS_LEFT=$(find "$WSS/data/firstboot" -maxdepth 1 \( -name last-attempt.json -o -name install-attempt.json -o -name auth-mode -o -name config-changes.json -o -name setup-failed -o -name submission-staging -o -name submission-active -o -name config.json \) | wc -l)
assert_eq "new machine starts without old configuration or recovery metadata" "$WS_LEFT" 0
for ws_file in last-attempt.json install-attempt.json auth-mode config-changes.json setup-failed submission-active; do
    printf this-machine >"$WSS/data/firstboot/$ws_file"
done
cp "$ROOT/config.reference.json" "$WSS/config.reference.json"
run_sourced "$WSS" eval 'publish_rig_defaults() { :; }; publish_saved_role() { :; }; publish_data_wipe_note() { :; }; installer_mode_available() { return 1; }; wizard_mint_cert() { :; }; stage_wizard_spool "$WSS/data/firstboot" && wizard_clear_submission_transaction "$WSS/data/firstboot"' >/dev/null
assert_rc "retry re-staging succeeds" "$?" 0
WS_LEFT=$(find "$WSS/data/firstboot" -maxdepth 1 \( -name last-attempt.json -o -name install-attempt.json -o -name auth-mode -o -name config-changes.json -o -name setup-failed -o -name submission-active \) | wc -l)
assert_eq "retry keeps all recovery files except the stale transaction" "$WS_LEFT" 5
assert_eq "retry preserves this machine's auth choice" "$(cat "$WSS/data/firstboot/auth-mode")" this-machine
run_sourced "$WSS" eval 'publish_rig_defaults() { return 1; }; stage_wizard_spool "$WSS/data/firstboot"' >/dev/null
assert_rc "retry staging propagates a failed derived-file publication" "$?" 1
PITHEAD_PRESEED_DIR="$WSS/preseed" run_sourced "$WSS" eval "$WS_NEW_MACHINE" >/dev/null 2>&1
assert_rc "the next machine reaches the same loading boundary" "$?" 7
WS_LEFT=$(find "$WSS/data/firstboot" -maxdepth 1 \( -name last-attempt.json -o -name install-attempt.json -o -name auth-mode -o -name config-changes.json -o -name setup-failed -o -name submission-active \) | wc -l)
assert_eq "the next machine cannot inherit the prior machine's recovery metadata" "$WS_LEFT" 0
mv "$WSS/data/firstboot" "$WSS/spool"
unset WS_NEW_MACHINE WS_LEFT ws_file
# A real UID boundary, not a mocked chown. CI's Linux runner supplies sudo and setpriv.
echo "== unit: wizard spool root and page ownership =="
if command -v setpriv >/dev/null && sudo -n true 2>/dev/null; then
    chmod 711 "$WSS"
    sudo bash -s -- "$STACK" "$WSS" <<'ROOTCHECK'
set -euo pipefail
source "$1"
spool="$2/root-spool"
prepare_wizard_spool "$spool"
page() { setpriv --reuid=1000 --regid=1000 --clear-groups "$@"; }
[ "$(stat -c '%u:%g:%a' "$spool")" = 0:1000:1770 ]
wizard_spool_publish "$spool" wizard.key printf fixture-key
[ "$(stat -c '%u:%g:%a' "$spool/wizard.key")" = 0:1000:640 ]
[ "$(page cat "$spool/wizard.key")" = fixture-key ]
! page rm -f "$spool/wizard.key" 2>/dev/null
! page sh -c 'printf altered >"$1"' _ "$spool/wizard.key" 2>/dev/null
for file in error.txt last-attempt.json installing setup-failed; do
    wizard_spool_publish "$spool" "$file" printf retry-fixture
    [ "$(stat -c '%u:%g:%a' "$spool/$file")" = 1000:1000:600 ]
    page rm "$spool/$file"
    page sh -c 'umask 077; printf retry >"$1"' _ "$spool/$file"
    [ "$(wizard_spool_read "$spool" "$file")" = retry ]
done
# Positive control: the hostile symlink can redirect a naive root writer on this fixture.
printf sentinel >"$2/root-target"
page ln -s "$2/root-target" "$spool/error.txt.link"
printf unsafe-control >"$spool/error.txt.link"
[ "$(cat "$2/root-target")" = unsafe-control ]
printf sentinel >"$2/root-target"
page ln -s "$2/root-target" "$spool/last-attempt.json.link"
wizard_spool_publish "$spool" last-attempt.json.link printf protected
[ "$(cat "$2/root-target")" = sentinel ]
# The page attempts replacement while the producer is holding a private inode open.
producer() {
    local dir
    dir=$(find "$spool" -maxdepth 1 -name '.host.*' -type d)
    ! page sh -c 'printf attack >"$1/value"' _ "$dir" 2>/dev/null
    printf protected
}
wizard_spool_publish "$spool" handoff.json producer
[ "$(page cat "$spool/handoff.json")" = protected ]
# Remove only fixture files, then empty fixture directories.
find "$spool" -maxdepth 1 -type f -delete
find "$spool" -maxdepth 1 -type l -delete
rmdir "$spool"
rm "$2/root-target"
ROOTCHECK
    assert_rc "real root/page read, refusal, retry, replacement and fired control" "$?" 0
else
    bad "real root/page boundary requires sudo and setpriv" "not run"
fi
rm -rf "$WSS"
unset WSS SNAP

# Lives in this domain rather than test-appliance-setup.sh, which owns the restore-at-setup
# contract: that file sits on the 400-line target and tests/stack/run.sh is on its own ceiling, so
# a new domain file cannot be registered. This domain already reaches into restore_apply's
# neighbourhood (the spool reader's limits above), which makes it the closest registered home.
echo "== unit: a restore onto a machine with no data/ yet (#2051) =="
# The condition the #1239 fixture removes. That one does `mkdir -p "$RT/data/tor"
# "$RT/data/dashboard"` before driving the restore, so the destinations always exist and the apply
# loop's `mv -T` always has a parent to move into. A real fresh disk has none: prepare_directories
# runs inside setup(), which both restore doors call AFTER the restore. On the bench the first tree
# item failed ENOENT, the apply returned early with config.json and .env ALREADY written, and the
# machine came up refusing setup as already provisioned with zero containers.
FR="$(cd "$SANDBOX" && pwd -P)/restore-fresh-machine"
mkdir -p "$FR/data/tor"
cp "$STACK" "$FR/pithead"
# Self-contained: this domain builds its own config rather than borrowing another's sandbox, so a
# standalone run of it proves the same thing the suite run does.
printf '{ "monero": {"mode":"local","wallet_address":"%s","node_username":"u","node_password":"p"}, "tari":{"wallet_address":"'"$VALID_TARI"'"}, "p2pool":{"pool":"main"}, "dashboard":{"secure":true,"host":"box.lan"} }\n' "$WALLET" >"$FR/config.json"
printf 'DEPLOYMENT_COMPLETED=true\nDASHBOARD_SECURE=true\nHOST_IP=box.lan\n' >"$FR/.env"
printf 'CADDY-ORIG\n' >"$FR/Caddyfile"
printf 'ONION-KEY-ORIG' >"$FR/data/tor/hostname"
tar -czf "$FR/fresh.tar.gz" -C / "${FR#/}/config.json" "${FR#/}/.env" "${FR#/}/Caddyfile" "${FR#/}/data/tor"
# THE CONDITION: no data/ at all, exactly as a freshly installed disk presents it.
rm -rf "$FR/data"
assert_eq "the fixture really is a fresh machine — no data/ to move into" \
    "$([ -e "$FR/data" ] || echo absent)" "absent"
run_sourced "$FR" restore_apply "$FR/fresh.tar.gz" '' "$FR/restore-error"
assert_rc "a restore onto a machine with no data/ succeeds" "$?" "0"
assert_eq "the archive's Tor identity lands under the created parent" \
    "$(cat "$FR/data/tor/hostname" 2>/dev/null)" "ONION-KEY-ORIG"
# The consequence that actually stranded the machine: the clear sits past the apply, so an apply
# that returned early left the carried marker standing and setup() refused headless (#924).
assert_eq "and the carried deployment marker is cleared, so setup can provision here" \
    "$(grep '^DEPLOYMENT_COMPLETED=' "$FR/.env")" "DEPLOYMENT_COMPLETED=false"
rm -rf "$FR"
