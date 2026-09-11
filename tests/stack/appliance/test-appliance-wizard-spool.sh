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
for ws_file in last-attempt.json install-attempt.json auth-mode config-changes.json setup-failed; do
    printf old-machine >"$WSS/spool/$ws_file"
done
# firstboot's canonical spool is data/firstboot; retain the same inode for the fixture.
mkdir "$WSS/data"
mv "$WSS/spool" "$WSS/data/firstboot"
PITHEAD_PRESEED_DIR="$WSS/preseed" run_sourced "$WSS" eval "$WS_NEW_MACHINE" >/dev/null 2>&1
assert_rc "new machine reaches the image-loading boundary" "$?" 7
WS_LEFT=$(find "$WSS/data/firstboot" -maxdepth 1 \( -name last-attempt.json -o -name install-attempt.json -o -name auth-mode -o -name config-changes.json -o -name setup-failed \) | wc -l)
assert_eq "new machine starts without old configuration or recovery metadata" "$WS_LEFT" 0
for ws_file in last-attempt.json install-attempt.json auth-mode config-changes.json setup-failed; do
    printf this-machine >"$WSS/data/firstboot/$ws_file"
done
cp "$ROOT/config.reference.json" "$WSS/config.reference.json"
run_sourced "$WSS" eval 'publish_rig_defaults() { :; }; publish_saved_role() { :; }; publish_data_wipe_note() { :; }; installer_mode_available() { return 1; }; wizard_mint_cert() { :; }; stage_wizard_spool "$WSS/data/firstboot"' >/dev/null
assert_rc "retry re-staging succeeds" "$?" 0
WS_LEFT=$(find "$WSS/data/firstboot" -maxdepth 1 \( -name last-attempt.json -o -name install-attempt.json -o -name auth-mode -o -name config-changes.json -o -name setup-failed \) | wc -l)
assert_eq "retry keeps all recovery files" "$WS_LEFT" 5
assert_eq "retry preserves this machine's auth choice" "$(cat "$WSS/data/firstboot/auth-mode")" this-machine
run_sourced "$WSS" eval 'publish_rig_defaults() { return 1; }; stage_wizard_spool "$WSS/data/firstboot"' >/dev/null
assert_rc "retry staging propagates a failed derived-file publication" "$?" 1
PITHEAD_PRESEED_DIR="$WSS/preseed" run_sourced "$WSS" eval "$WS_NEW_MACHINE" >/dev/null 2>&1
assert_rc "the next machine reaches the same loading boundary" "$?" 7
WS_LEFT=$(find "$WSS/data/firstboot" -maxdepth 1 \( -name last-attempt.json -o -name install-attempt.json -o -name auth-mode -o -name config-changes.json -o -name setup-failed \) | wc -l)
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
