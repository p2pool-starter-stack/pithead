# shellcheck shell=bash
: "${STACK_SUITE:?is unset: this file is a tests/stack/run.sh fragment, not a script — run tests/stack/run.sh}"
# Restore-at-setup domain (#1105 Phase 1, appliance lane): firstboot_consume_restore, the wizard's
# alternative to the config form — an uploaded encrypted backup archive adopted in place of a fresh
# provisioning (#909, #786 sub-issue B) — plus the installer's restore onto target data
# (install_restore_to_target), the legacy carried-ESP door (consume_preseed_restore), the volatile
# cleanup helpers (#1854) and the restore_apply/restore_setup_* primitives they share. Split out of
# test-appliance-setup.sh (#2195): that file's own token/spool and uninstall sections are a
# different behaviour boundary and do not touch $RS or any restore primitive.
# Sourced by tests/stack/run.sh.
#
# Re-derivations:
# - $WALLET and build_val_sandbox(): lib.sh's build_val_sandbox() sets $WALLET as a global; this
#   file self-arms with its own call rather than inheriting one from an earlier domain, the same
#   idiom (and the same idempotence) test-appliance-setup.sh's own header documents at length —
#   see that file for the full reasoning; it is not repeated here since nothing in it is specific
#   to restore.
# - $VALID_TARI, $SANDBOX, $ROOT and $STACK are lib.sh top-level globals, as are the assertion
#   helpers this domain calls (assert_eq, assert_rc, assert_contains, assert_not_contains, ok, bad)
#   and run_sourced.
build_val_sandbox

echo "== unit: firstboot_consume_restore — restore-at-setup (#909, #786 sub-issue B) =="
# A genuine encrypted backup (the same `pithead backup` #908 rides), fed through the wizard's
# restore-consume exactly as the host loop would: decrypt, verify BEFORE anything is touched,
# validate the embedded config through a copy, and land it as a normal accepted config.json —
# the SAME contract firstboot_consume_spool gives a typed submission. Physical path (#695): see
# the backup/restore black-box block above for why `pwd -P` matters here too.
RS="$(cd "$SANDBOX" && pwd -P)/restore-consume"
mkdir -p "$RS/build/tari" "$RS/data/tor" "$RS/data/dashboard" "$RS/bin" "$RS/volatile" "$RS/stage"
export PITHEAD_RESTORE_STAGE_ROOT="$RS/stage"
cp "$STACK" "$RS/pithead"
cp "$ROOT/build/tari/config.toml.template" "$RS/build/tari/"
cp "$ROOT/docker-compose.yml" "$RS/docker-compose.yml" # caddy_hash_password_b64 reads the pinned image from here
cat >"$RS/bin/docker" <<'EOF'
#!/usr/bin/env bash
case "$*" in
  "compose ps --status running -q") exit 0 ;; # empty output -> stack treated as not running
  *hash-password*)
    # Fake `caddy hash-password` (matches lib.sh's make_stubs): the restore fixtures below carry a
    # real dashboard.auth.password, and a restore whose live .env lost its matching fingerprint
    # (an earlier case in this file re-derived it without one) falls through to actually hashing.
    _pw="${*##*--plaintext }"
    _d="$(printf '%s' "$_pw" | { sha256sum 2>/dev/null || shasum -a 256; } | cut -c1-22)"
    printf '$2y$14$%s\n' "$_d"
    ;;
esac
exit 0
EOF
cat >"$RS/bin/sudo" <<'EOF'
#!/usr/bin/env bash
[ "$1" = "chown" ] && exit 0
exec "$@"
EOF
chmod +x "$RS/bin/docker" "$RS/bin/sudo"
RS_AUTH_PASSWORD="restore auth password"
RS_ARCHIVE_AUTH_HASH=$(printf '%s' '$2a$14$abcdefghijklmnopqrstuuuuuuuuuuuuuuuuuuuuuuuuuuuuuuuuu' | openssl base64 -A)
RS_AUTH_FP=$(printf '%s' "$RS_AUTH_PASSWORD" | sha256sum | cut -d' ' -f1)
RS_EXPECTED_AUTH_HASH=$(PATH="$RS/bin:$PATH" run_sourced "$RS" caddy_hash_password_b64 "$RS_AUTH_PASSWORD")
cat >"$RS/.env" <<EOF
MONERO_ONION_ADDRESS=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa.onion
TARI_ONION_ADDRESS=bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb.onion
P2POOL_ONION_ADDRESS=cccccccccccccccccccccccccccccccccccccccccccccccccccccccc.onion
PROXY_AUTH_TOKEN=0123456789abcdef01234567
DASHBOARD_AUTH_HASH_B64=$RS_ARCHIVE_AUTH_HASH
DASHBOARD_AUTH_PW_FP=$RS_AUTH_FP
HOST_IP=box.lan
DEPLOYMENT_COMPLETED=true
COMPOSE_PROFILES=local_node
EOF
printf '{ "monero": {"mode":"local","wallet_address":"%s","node_username":"u","node_password":"p"}, "tari":{"wallet_address":"'"$VALID_TARI"'"}, "p2pool":{"pool":"main"}, "dashboard":{"secure":true,"host":"box.lan","auth":{"username":"admin","password":"%s"}} }\n' "$WALLET" "$RS_AUTH_PASSWORD" >"$RS/config.json"

# A pair pithead rendered carries a hash of exactly the configured password, so canonicalization
# keeps it byte-for-byte while its fingerprint matches (#2579); a salted rehash would change the
# credential the safety rollback compares. A stale pair is hashed again from the plaintext.
RSAUTH="$RS/auth-canonical" && mkdir -p "$RSAUTH"
cp "$RS/config.json" "$RSAUTH/config.json"
printf 'DASHBOARD_AUTH_HASH_B64=%s\nDASHBOARD_AUTH_PW_FP=%s\n' "$RS_ARCHIVE_AUTH_HASH" "$RS_AUTH_FP" >"$RSAUTH/.env"
PATH="$RS/bin:$PATH" run_sourced "$RS" restore_canonicalize_derived "$RSAUTH/config.json" "$RSAUTH/.env" "$RSAUTH/Caddyfile"
assert_rc "restore auth canonicalization accepts disposable credentials" "$?" 0
assert_eq "restore auth canonicalization preserves the plaintext password" "$(jq -r '.dashboard.auth.password' "$RSAUTH/config.json")" "$RS_AUTH_PASSWORD"
assert_eq "restore auth canonicalization preserves the archived bcrypt for that password" "$(sed -n 's/^DASHBOARD_AUTH_HASH_B64=//p' "$RSAUTH/.env")" "$RS_ARCHIVE_AUTH_HASH"
assert_eq "restore auth canonicalization preserves its matching fingerprint" "$(sed -n 's/^DASHBOARD_AUTH_PW_FP=//p' "$RSAUTH/.env")" "$RS_AUTH_FP"
printf 'DASHBOARD_AUTH_HASH_B64=%s\nDASHBOARD_AUTH_PW_FP=%s\n' "$RS_ARCHIVE_AUTH_HASH" "$(printf '%s' 'an older password' | sha256sum | cut -d' ' -f1)" >"$RSAUTH/.env"
PATH="$RS/bin:$PATH" run_sourced "$RS" restore_canonicalize_derived "$RSAUTH/config.json" "$RSAUTH/.env" "$RSAUTH/Caddyfile"
assert_rc "restore auth canonicalization accepts a stale pair" "$?" 0
assert_eq "restore auth canonicalization regenerates the bcrypt for a stale pair" "$(sed -n 's/^DASHBOARD_AUTH_HASH_B64=//p' "$RSAUTH/.env")" "$RS_EXPECTED_AUTH_HASH"
assert_eq "restore auth canonicalization regenerates the fingerprint for a stale pair" "$(sed -n 's/^DASHBOARD_AUTH_PW_FP=//p' "$RSAUTH/.env")" "$RS_AUTH_FP"
rm -rf "$RSAUTH"
printf 'CADDY-ORIG\n' >"$RS/Caddyfile"
printf 'ONIONKEY-ORIG\n' >"$RS/data/tor/hs_ed25519_secret_key"
printf 'DBDATA-ORIG\n' >"$RS/data/dashboard/dashboard.db"
out="$(cd "$RS" && PATH="$RS/bin:$PATH" PITHEAD_BACKUP_PASSPHRASE=hunter2 ./pithead backup -y 2>&1)"
rc=$?
assert_rc "restore fixture: backup exits 0" "$rc" "0"
rarchive="$(ls "$RS"/backups/pithead-backup-*.tar.gz.enc 2>/dev/null | head -1)"
{ [ -n "$rarchive" ] && [ -f "$rarchive" ]; } && ok "restore fixture: encrypted archive created" || bad "restore fixture: encrypted archive created" "no .enc archive"

RSPOOL="$RS/data/firstboot-test" && mkdir -p "$RSPOOL" && rm -f "$RS/config.json"

# 1) Accept: the right passphrase decrypts, verifies, validates and lands config.json — settings,
# the Tor identity and the dashboard database all come back, and neither the archive nor the
# passphrase survive the attempt.
cp "$rarchive" "$RSPOOL/restore-archive" && printf 'hunter2' >"$RSPOOL/restore-passphrase" # test fixture, not a real secret
out=$(cd "$RS" && PATH="$RS/bin:$PATH" run_sourced "$RS" eval 'mktemp() { case "$*" in -d\ */.restore.*) printf "%s\n" "$*" >>"$RS/stage-pattern" ;; esac; command mktemp "$@"; }; firstboot_consume_restore "$RSPOOL"' && echo rc0)
assert_contains "valid restore accepted" "$out" "rc0"
assert_eq "valid restore installs config.json" "$([ -f "$RS/config.json" ] && echo yes)" "yes"
assert_contains "valid restore carries the original wallet" "$(cat "$RS/config.json" 2>/dev/null)" "$WALLET"
assert_contains "valid restore regenerates the Caddyfile from config" "$(cat "$RS/Caddyfile" 2>/dev/null)" "reverse_proxy 127.0.0.1:8000"
assert_eq "valid restore brings back the dashboard db" "$(cat "$RS/data/dashboard/dashboard.db" 2>/dev/null)" "DBDATA-ORIG"
assert_eq "valid restore marks the sync gate for re-derivation (#2626)" "$([ -f "$RS/data/dashboard/sync-gate-reset" ] && echo yes)" yes
assert_eq "valid restore preserves the dashboard password" "$(jq -r '.dashboard.auth.password' "$RS/config.json")" "$RS_AUTH_PASSWORD"
assert_eq "valid restore preserves the archived dashboard credential hash" "$(sed -n 's/^DASHBOARD_AUTH_HASH_B64=//p' "$RS/.env")" "$RS_ARCHIVE_AUTH_HASH"
assert_eq "valid restore preserves the dashboard password fingerprint" "$(sed -n 's/^DASHBOARD_AUTH_PW_FP=//p' "$RS/.env")" "$RS_AUTH_FP"
assert_eq "applied marker set" "$([ -f "$RSPOOL/applied" ] && echo yes)" "yes"
assert_eq "the archive is consumed" "$([ -f "$RSPOOL/restore-archive" ] || echo gone)" "gone"
assert_eq "the passphrase is never retained" "$([ -f "$RSPOOL/restore-passphrase" ] || echo gone)" "gone"

# The wizard and carried-ESP doors share restore_apply. Prove that a valid config cannot smuggle
# generated runtime policy through either archive .env or Caddyfile, while its generated identity
# still survives the canonical re-render.
RH="$RS/stale-derived"
mkdir -p "$RH/${RS#/}"
jq 'del(.dashboard.auth)' "$RS/config.json" >"$RH/${RS#/}/config.json"
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

# 1b) Installer door (installer=1): the config surfaces for the credentials card, but the
# machine itself is NOT restored — decrypted keys must never rest on the stick — and the
# accepted archive + passphrase park in the volatile carry dir, never the ESP, for the install
# branch to apply straight onto the target's data (install_restore_to_target, below).
printf 'STICK-CADDY\n' >"$RS/Caddyfile"
printf 'STICK-DB\n' >"$RS/data/dashboard/dashboard.db"
cp "$rarchive" "$RSPOOL/restore-archive"
RSECRET="$RS/volatile/submission"
mkdir "$RSECRET"
printf 'hunter2' >"$RSECRET/restore-passphrase" # test fixture, not a real secret
RCARRY="$RS/volatile/carry"
RCANDIDATE="$RS/volatile/config.json" && rm -f "$RS/data/dashboard/sync-gate-reset"
out=$(cd "$RS" && PATH="$RS/bin:$PATH" PITHEAD_RESTORE_CARRY_DIR="$RCARRY" run_sourced "$RS" eval '
    mktemp() { case "$*" in -d\ */.restore.*) printf "%s\n" "$*" >>"$RS/stage-pattern" ;; esac; command mktemp "$@"; }
    firstboot_consume_restore "$RSPOOL" 1 "$RSECRET" "$RCANDIDATE"
' && echo rc0)
assert_contains "installer restore accepted" "$out" "rc0"
assert_contains "installer restore surfaces a volatile config for the card" "$(cat "$RCANDIDATE" 2>/dev/null)" "$WALLET"
assert_eq "installer restore leaves no config on the stick data" "$([ -e "$RS/config.json" ] || echo gone)" gone
assert_eq "installer restore does NOT restore onto the stick (Caddyfile untouched)" "$(cat "$RS/Caddyfile")" "STICK-CADDY"
assert_eq "installer restore does NOT restore onto the stick (db untouched)" "$(cat "$RS/data/dashboard/dashboard.db")" "STICK-DB"
assert_eq "accepted archive parked only in volatile carry" "$([ -f "$RCARRY/archive" ] && echo yes)" "yes"
assert_eq "passphrase parked only in volatile carry" "$(cat "$RCARRY/pass" 2>/dev/null)" "hunter2"
assert_eq "installer restore leaves no sync-gate marker on the stick" "$([ -e "$RS/data/dashboard/sync-gate-reset" ] || echo none)" none
assert_eq "installer restore consumes the spool archive" "$([ -f "$RSPOOL/restore-archive" ] || echo gone)" "gone"
assert_eq "installer restore consumes the volatile submitted passphrase" "$([ -f "$RSECRET/restore-passphrase" ] || echo gone)" gone

# A failure after acceptance must take the volatile candidate and carry with it.
cp "$rarchive" "$RSPOOL/restore-archive" && printf hunter2 >"$RSECRET/restore-passphrase"
RFAILCARRY="$RS/volatile/failure-carry"
RFAILCONFIG="$RS/volatile/failure-config.json"
out=$(cd "$RS" && PITHEAD_RESTORE_CARRY_DIR="$RFAILCARRY" run_sourced "$RS" eval 'wizard_spool_publish() { [ "$2" != restore-inflight ]; }; firstboot_consume_restore "$RSPOOL" 1 "$RSECRET" "$RFAILCONFIG" || echo "rc$?"')
assert_contains "marker publication failure rejects the restore" "$out" rc1
assert_eq "marker publication failure clears the volatile candidate" "$([ -e "$RFAILCONFIG" ] || echo gone)" gone
assert_eq "marker publication failure clears the volatile carry" "$([ -e "$RFAILCARRY" ] || echo gone)" gone

# consume_install_request runs pithead-install with --no-preseeds when it carries a restore, so no
# unrelated pre-seed reaches the target; a target restore that cannot clear its temporaries then
# fails the install, with a generic reason on the page. Driven against a fake pithead-install.
RINST="$RS/install-sandbox"
mkdir -p "$RINST/spool" "$RINST/carry"
cat >"$RINST/fake-install" <<'FAKE'
#!/usr/bin/env bash
case "$1" in
--list) printf 'vda\t40G\tFake Disk\tSN1\tempty\n' ;;
--target) case " $* " in *" --no-preseeds "*) : >"${FAKE_SKIP:?}" ;; esac ;;
esac
FAKE
chmod +x "$RINST/fake-install"
touch "$RINST/carry/archive"
printf cleanup-fixture-secret >"$RINST/carry/pass"
printf 'vda\tkeep' >"$RINST/spool/install-request"
PITHEAD_INSTALL_BIN="$RINST/fake-install" FAKE_SKIP="$RINST/skipped-preseeds" run_sourced "$RS" eval 'install_restore_to_target() { printf "%s\n" "Could not clear temporary target restore files safely." >&2; return 1; }; consume_install_request "$RINST/spool" "" "$RINST/carry"' >/dev/null 2>&1
assert_rc "target restore cleanup failure rejects the install" "$?" 1
assert_eq "restore installs suppress unrelated pre-seed copies" "$([ -f "$RINST/skipped-preseeds" ] && echo yes)" yes
assert_contains "target restore cleanup failure reaches the page" "$(cat "$RINST/spool/error.txt")" 'Could not clear temporary target restore files safely'
assert_not_contains "target restore cleanup failure never reveals the passphrase" "$(cat "$RINST/spool/error.txt")" cleanup-fixture-secret
rm -rf "$RINST"

# The installer applies the parked restore to the target's data partition (faked here as a
# directory): a failed finalization leaves first boot fail-closed on .restore-incomplete, a
# symlinked target root or leaf is refused rather than followed, and only a non-secret pending
# marker reaches target data. The target is a kept one (#2230): its prior config and role marker
# are replaced by the restore's, while its chain data stays for the merge.
RDATA="$RS/target-data"
mkdir -p "$RDATA/pithead/data/monero"
printf '{"monero":{"wallet_address":"4kept"}}' >"$RDATA/pithead/config.json"
printf 'rig\n' >"$RDATA/pithead/machine-role"
printf 'KEEP-monero\n' >"$RDATA/pithead/data/monero/chain-sentinel"
out=$(cd "$RS" && PATH="$RS/bin:$PATH" RDATA="$RDATA" run_sourced "$RS" eval '
    systemd-repart() { :; }
    udevadm() { :; }
    lsblk() { printf "/dev/fake4 data\n"; }
    mount() { local p="${*: -1}"; rmdir "$p" && ln -s "$RDATA" "$p"; }
    umount() { local p="$1"; rm "$p" && mkdir "$p"; }
    mktemp() { case "$*" in -d\ */.restore.*) printf "%s\n" "$*" >>"$RS/stage-pattern" ;; esac; command mktemp "$@"; }
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
assert_eq "target restore keeps the kept target's chain data" "$(cat "$RDATA/pithead/data/monero/chain-sentinel" 2>/dev/null)" KEEP-monero
assert_eq "target restore marks the sync gate for re-derivation (#2626)" "$([ -f "$RDATA/pithead/data/dashboard/sync-gate-reset" ] && echo yes)" yes
assert_eq "target restore lands the archive's .env on the target" "$([ -f "$RDATA/pithead/.env" ] && echo yes)" yes
assert_eq "target restore leaves the installer's own files untouched" "$(cat "$RS/Caddyfile")" STICK-CADDY
assert_contains "target restore leaves only a non-secret pending marker" "$out" pending-marker-kept
assert_eq "a refused target restore disarms the pending marker" "$([ -e "$RDATA/pithead/.restore-pending" ] || echo gone)" gone
assert_eq "target data holds no persisted passphrase file" "$(find "$RDATA" -name '*restore-pass*' -print -quit)" ""
assert_eq "target data holds no second encrypted carry" "$(find "$RDATA" -name 'pithead-restore.enc' -print -quit)" ""
assert_contains "restore decrypt staging uses the dedicated volatile root" "$(cat "$RS/stage-pattern")" "-d $RS/stage/.restore.XXXXXXXXXX"
assert_eq "restore decrypt staging never follows the carry parent" "$(awk -v p="-d $RS/stage/.restore.XXXXXXXXXX" '$0 != p {print}' "$RS/stage-pattern")" ""

# Volatile cleanup failures are reported, never hidden, and never echo the secret they failed on.
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

# 1c) A genuine backup made from a DIFFERENT working directory than this appliance's — exactly
# what the supported v1.20.0 Compose bundle produces, since its `pithead backup` ran from
# wherever the operator extracted the bundle, never this box's directory (#2181). Every member is
# still rooted at ONE directory (the bundle's own, not $RS), so it must restore just as a
# same-directory backup does.
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
# A SECOND name in each chain dir, the one the target plants too (#2195): the archive therefore
# ships both a name the target lacks (the sentinels above) and a name it already holds (these), so
# the merge's two halves — add what is missing, keep what is already there — each get their own row.
printf 'MONERO-CHAIN-OLDROOT\n' >"$OLDROOT/data/monero/chain-state"
printf 'TARI-CHAIN-OLDROOT\n' >"$OLDROOT/data/tari/chain-state"
printf 'P2POOL-CHAIN-OLDROOT\n' >"$OLDROOT/data/p2pool/chain-state"
# --with-chains: the issue's own repro (#2181) backs up Monero/Tari/P2Pool data too, so the
# cross-root restore below has to prove those trees, not just config/Tor/dashboard.
out="$(cd "$OLDROOT" && PATH="$OLDROOT/bin:$PATH" PITHEAD_BACKUP_PASSPHRASE=hunter2 ./pithead backup --with-chains -y 2>&1)"
rc=$?
assert_rc "cross-root fixture: backup exits 0" "$rc" "0"
oldarchive="$(ls "$OLDROOT"/backups/pithead-backup-*.tar.gz.enc 2>/dev/null | head -1)"
{ [ -n "$oldarchive" ] && [ -f "$oldarchive" ]; } && ok "cross-root fixture: encrypted archive created" || bad "cross-root fixture: encrypted archive created" "no .enc archive"
cp "$oldarchive" "$RSPOOL/restore-archive" && printf 'hunter2' >"$RSPOOL/restore-passphrase" # test fixture, not a real secret

# #2195: the TARGET already carries its OWN chain data — a wipe=keep reinstall — at the EXACT
# same paths the archive also ships, with DIFFERENT content: a genuine name collision, not merely
# a name the archive lacks. The wizard restore's collision rule is "the target wins" (its own
# synced chain data must never be forced into a resync); the admin `pithead restore` CLI command
# has the opposite rule for the same collision (restore_commit_stage's `cp -a --remove-destination`
# lets the archive win — an operator running that command explicitly wants the archive back). See
# docs/operations.md's "Restore collision rules" for that deliberate divergence. Distinct
# content on each side is what makes this a real collision test: `chain-state` is a name the archive
# ships too, so restore_apply's `cp -a -n` (no-clobber) is what the collision rows below actually
# exercise — remove the `-n` and the archive's content would win here instead, and they go red.
mkdir -p "$RS/data/monero" "$RS/data/tari" "$RS/data/p2pool" # the target's chain dirs; only `wipe=keep` leaves them behind, and this fixture is a fresh $RS
printf 'MONERO-CHAIN-TARGET\n' >"$RS/data/monero/chain-state"
printf 'TARI-CHAIN-TARGET\n' >"$RS/data/tari/chain-state"
printf 'P2POOL-CHAIN-TARGET\n' >"$RS/data/p2pool/chain-state"
# The restore's own success is asserted FIRST and separately from the collision survival checks
# below: a restore that silently failed would leave the just-planted target content untouched too,
# which would otherwise let those checks pass without the merge logic having run at all.
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

# Expected-member policy is shared by the wizard and carried-archive doors (#1971).
# These are ordinary fixture files. The added note is outside the backup item list.
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
