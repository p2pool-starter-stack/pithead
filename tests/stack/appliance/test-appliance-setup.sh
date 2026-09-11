# shellcheck shell=bash
: "${STACK_SUITE:?is unset: this file is a tests/stack/run.sh fragment, not a script — run tests/stack/run.sh}"
# Appliance setup domain (#1105 Phase 1, appliance lane): the firstboot provisioning path an
# appliance walks the first time it is powered on, and the uninstall contract that path has to
# survive — the wizard's minted pairing token and its spool consume (#77 phase 3), the
# restore-at-setup leg where firstboot_consume_restore adopts an operator's encrypted backup
# archive instead of provisioning a fresh stack (#909, #786 sub-issue B), and the black-box
# guarantee that `uninstall` removes only what the stack rendered and keeps the operator's own
# files (#77 phase 1).
# Sourced by tests/stack/run.sh.
#
# Re-derivations:
# - $V, $WALLET and seed_env(): all three are lib.sh's build_val_sandbox() — $V and $WALLET as
#   globals, seed_env() as a function defined inside that builder's body, so it does not exist
#   until the builder has run. In run.sh these arrived ambiently from the far-earlier config and
#   dashboard domains, which call the builder for their own reasons; neither is an appliance-setup
#   concern, so this file self-arms instead of inheriting. build_val_sandbox() is idempotent — a
#   fixed $SANDBOX/val path, mkdir -p, and template copies, with no removal of the .env or
#   config.json this domain writes — so the call is a safe re-affirm as currently sourced, and it
#   is what makes the file sourceable standalone under `set -u`.
# - The neighbouring warning against this exact call, and why it does not reach it.
#   test-doctor-appliance.sh — sourced one stanza above this file — warns explicitly against
#   calling build_val_sandbox() again, because doing so would reset the shared "$SANDBOX/val" out
#   from under the config-validation / dashboard / payout sections that were still threaded through
#   run.sh when that comment was written; it mirrors the builder's body under a non-colliding name
#   instead. That warning is about CLOBBERING A NEIGHBOUR, and it does not reach this call: every
#   domain file sourced after this one that reads $V or seed_env() outside a comment self-arms at
#   its own entry, and the builder writes neither the .env nor the config.json this domain writes.
#   It is cited here rather than left implicit because "idempotent" is the word a future author
#   will reuse without re-running that audit, and a build_val_sandbox call placed elsewhere in this
#   neighbourhood could genuinely clobber, exactly as that warning says.
# - $VALID_TARI is a plain lib.sh top-level constant, not build_val_sandbox()-scoped, so it needs
#   no arming here.
# - $SANDBOX, $ROOT and $STACK are lib.sh top-level globals, as are the assertion helpers this
#   domain calls (assert_eq, assert_rc, assert_contains, ok, bad) and run_sourced.
# - The uninstall section closes by re-rendering the sandbox .env and config.json, because
#   `uninstall -y` has just deleted them. That tail is retained here verbatim rather than dropped:
#   the source stanza sits at this block's exact former position in run.sh, so the re-render still
#   precedes exactly the successors it preceded before, and execution order is unchanged by the
#   move. Relocating the stanza would make that tail a live ordering decision rather than a
#   no-op, which is why the anchor is the block's own vacated position.
build_val_sandbox

echo "== unit: firstboot wizard token + spool consume (#77 phase 3) =="
# Token: pit- prefix + 6 chars from the unambiguous alphabet (never 0, O, 1, I, or l).
tok=$(run_sourced "$SANDBOX" wizard_mint_token)
assert_eq "token shape" "$(printf '%s' "$tok" | grep -cE '^pit-[23456789ABCDEFGHJKMNPQRSTUVWXYZ]{6}$')" "1"
tok2=$(run_sourced "$SANDBOX" wizard_mint_token)
assert_eq "tokens vary" "$([ "$tok" = "$tok2" ] && echo same || echo differ)" "differ"
# Consume: a valid submission installs config.json + marks applied; an invalid one surfaces the
# error into the spool for the form and installs nothing; an empty spool is rc 2.
WSPOOL="$V/data/firstboot-test"
mkdir -p "$WSPOOL"
rm -f "$V/config.json"
printf '{ "monero": {"wallet_address":"%s"}, "tari":{"wallet_address":"'"$VALID_TARI"'"}, "p2pool":{"pool":"mini","stratum_password":"auto"} }\n' "$WALLET" >"$WSPOOL/config.json"
out=$(cd "$V" && PATH="$V/bin:$PATH" run_sourced "$V" firstboot_consume_spool "$WSPOOL" && echo rc0)
assert_contains "valid submission accepted" "$out" "rc0"
assert_eq "valid submission installs config.json" "$([ -f "$V/config.json" ] && echo yes)" "yes"
assert_eq "applied marker set" "$([ -f "$WSPOOL/applied" ] && echo yes)" "yes"
rm -f "$WSPOOL/applied"
printf '{ "monero": {"wallet_address":"8-not-a-primary"}, "tari":{"wallet_address":"'"$VALID_TARI"'"}, "p2pool":{"pool":"mini"} }\n' >"$WSPOOL/config.json"
out=$(cd "$V" && PATH="$V/bin:$PATH" run_sourced "$V" firstboot_consume_spool "$WSPOOL" || echo "rc$?")
assert_contains "invalid submission rejected" "$out" "rc1"
assert_eq "rejection surfaces spool error" "$([ -s "$WSPOOL/error.txt" ] && echo yes)" "yes"
assert_eq "rejection leaves no candidate" "$([ -f "$WSPOOL/config.json" ] || echo gone)" "gone"
out=$(run_sourced "$V" firstboot_consume_spool "$WSPOOL" || echo "rc$?")
assert_contains "empty spool is rc2" "$out" "rc2"
rm -rf "$WSPOOL"
# Restore the sandbox config for later sections.
printf '{ "monero": {"mode":"local","wallet_address":"%s","node_username":"u","node_password":"p"}, "tari":{"wallet_address":"'"$VALID_TARI"'"}, "p2pool":{"pool":"main"}, "dashboard":{"secure":true,"host":"box.lan"} }\n' "$WALLET" >"$V/config.json"
# A missing env file is a hard error, not an empty render.
out=$(run_sourced "$SANDBOX" render_quadlet_units "$SANDBOX/no-such.env" "$SANDBOX/quadlet-none" 2>&1)
assert_contains "render-quadlet missing env errors" "$out" "env file not found"

echo "== unit: firstboot_consume_restore — restore-at-setup (#909, #786 sub-issue B) =="
# A genuine encrypted backup (the same `pithead backup` #908 rides), fed through the wizard's
# restore-consume exactly as the host loop would: decrypt, verify BEFORE anything is touched,
# validate the embedded config through a copy, and land it as a normal accepted config.json —
# the SAME contract firstboot_consume_spool gives a typed submission. Physical path (#695): see
# the backup/restore black-box block above for why `pwd -P` matters here too.
RS="$(cd "$SANDBOX" && pwd -P)/restore-consume"
mkdir -p "$RS/build/tari" "$RS/data/tor" "$RS/data/dashboard" "$RS/bin"
cp "$STACK" "$RS/pithead"
cp "$ROOT/build/tari/config.toml.template" "$RS/build/tari/"
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
printf 'CADDY-ORIG\n' >"$RS/Caddyfile"
printf 'ONIONKEY-ORIG\n' >"$RS/data/tor/hs_ed25519_secret_key"
printf 'DBDATA-ORIG\n' >"$RS/data/dashboard/dashboard.db"
out="$(cd "$RS" && PATH="$RS/bin:$PATH" PITHEAD_BACKUP_PASSPHRASE=hunter2 ./pithead backup -y 2>&1)"
rc=$?
assert_rc "restore fixture: backup exits 0" "$rc" "0"
rarchive="$(ls "$RS"/backups/pithead-backup-*.tar.gz.enc 2>/dev/null | head -1)"
{ [ -n "$rarchive" ] && [ -f "$rarchive" ]; } && ok "restore fixture: encrypted archive created" || bad "restore fixture: encrypted archive created" "no .enc archive"

RSPOOL="$RS/data/firstboot-test"
mkdir -p "$RSPOOL"
rm -f "$RS/config.json"

# 1) Accept: the right passphrase decrypts, verifies, validates and lands config.json — settings,
# the Tor identity and the dashboard database all come back, and neither the archive nor the
# passphrase survive the attempt.
cp "$rarchive" "$RSPOOL/restore-archive"
printf 'hunter2' >"$RSPOOL/restore-passphrase" # test fixture, not a real secret
out=$(cd "$RS" && PATH="$RS/bin:$PATH" run_sourced "$RS" firstboot_consume_restore "$RSPOOL" && echo rc0)
assert_contains "valid restore accepted" "$out" "rc0"
assert_eq "valid restore installs config.json" "$([ -f "$RS/config.json" ] && echo yes)" "yes"
assert_contains "valid restore carries the original wallet" "$(cat "$RS/config.json" 2>/dev/null)" "$WALLET"
assert_contains "valid restore regenerates the Caddyfile from config" "$(cat "$RS/Caddyfile" 2>/dev/null)" "reverse_proxy 127.0.0.1:8000"
assert_eq "valid restore brings back the dashboard db" "$(cat "$RS/data/dashboard/dashboard.db" 2>/dev/null)" "DBDATA-ORIG"
assert_eq "applied marker set" "$([ -f "$RSPOOL/applied" ] && echo yes)" "yes"
assert_eq "the archive is consumed" "$([ -f "$RSPOOL/restore-archive" ] || echo gone)" "gone"
assert_eq "the passphrase is never retained" "$([ -f "$RSPOOL/restore-passphrase" ] || echo gone)" "gone"

# The wizard and carried-ESP doors share restore_apply. Prove that a valid config cannot smuggle
# generated runtime policy through either archive .env or Caddyfile, while its generated identity
# still survives the canonical re-render.
RH="$RS/stale-derived"
mkdir -p "$RH/${RS#/}"
cp "$RS/config.json" "$RH/${RS#/}/config.json"
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
tar -czf "$RSPOOL/restore-archive" -C "$RH" "${RS#/}/config.json" "${RS#/}/.env" "${RS#/}/Caddyfile"
: >"$RSPOOL/restore-passphrase"
rm -f "$RSPOOL/applied"
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
# accepted archive + passphrase park in the carry dir for the ESP staging the install branch
# performs (the target's first boot does the real restore).
printf 'STICK-CADDY\n' >"$RS/Caddyfile"
printf 'STICK-DB\n' >"$RS/data/dashboard/dashboard.db"
cp "$rarchive" "$RSPOOL/restore-archive"
printf 'hunter2' >"$RSPOOL/restore-passphrase" # test fixture, not a real secret
RCARRY="$RS/carry"
out=$(cd "$RS" && PATH="$RS/bin:$PATH" PITHEAD_RESTORE_CARRY_DIR="$RCARRY" run_sourced "$RS" firstboot_consume_restore "$RSPOOL" 1 && echo rc0)
assert_contains "installer restore accepted" "$out" "rc0"
assert_contains "installer restore surfaces the config for the card" "$(cat "$RS/config.json" 2>/dev/null)" "$WALLET"
assert_eq "installer restore does NOT restore onto the stick (Caddyfile untouched)" "$(cat "$RS/Caddyfile")" "STICK-CADDY"
assert_eq "installer restore does NOT restore onto the stick (db untouched)" "$(cat "$RS/data/dashboard/dashboard.db")" "STICK-DB"
assert_eq "accepted archive parked for the ESP carry" "$([ -f "$RCARRY/archive" ] && echo yes)" "yes"
assert_eq "passphrase parked beside it" "$(cat "$RCARRY/pass" 2>/dev/null)" "hunter2"
assert_eq "installer restore consumes the spool archive" "$([ -f "$RSPOOL/restore-archive" ] || echo gone)" "gone"
rm -rf "$RCARRY"
rm -f "$RSPOOL/applied" "$RS/config.json"
printf 'CADDY-ORIG\n' >"$RS/Caddyfile" # fixtures back to their case-1 state for the cases below
printf 'DBDATA-ORIG\n' >"$RS/data/dashboard/dashboard.db"

# Expected-member policy is shared by the wizard and carried-archive doors (#1971).
# These are ordinary fixture files. The added note is outside the backup item list.
run_sourced "$RS" restore_setup_members "${RS#/}/config.json"
assert_rc "member policy accepts a mapped configuration file" "$?" 0
run_sourced "$RS" restore_setup_members "${RS#/}/data/tor/"
assert_rc "member policy accepts a mapped data directory" "$?" 0
run_sourced "$RS" restore_setup_members "${RS#/}/config.json/"
assert_rc "member policy refuses a directory in place of configuration" "$?" 1
run_sourced "$RS" restore_setup_members "${RS#/}/data/tor"
assert_rc "member policy refuses a file in place of a data directory" "$?" 1
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
mkdir "$RS/list-fixture"
for n in $(seq 1 200); do printf x >"$RS/list-fixture/member-$n-abcdefghijklmnopqrstuvwxyz"; done
tar -czf "$RS/list-fixture.tar.gz" -C "$RS/list-fixture" .
if run_sourced "$RS" restore_setup_tar_list "$RS/list-fixture.tar.gz" -tvzf "$RS/list-output" 1 30; then out=accepted; else out=refused; fi
assert_eq "archive listing is stopped at its output cap" "$out" refused
rm -f "$RS/restore-names" "$RS/restore-verbose"
RPSEED="$RS/preseed"
mkdir "$RPSEED"
cp "$rarchive" "$RPSEED/pithead-restore.enc"
printf hunter2 >"$RPSEED/pithead-restore-pass"
out=$(PITHEAD_PRESEED_DIR="$RPSEED" run_sourced "$RS" eval 'mount() { :; }; consume_preseed_restore && echo rc0')
assert_contains "carried normal backup passes the shared member policy" "$out" rc0
assert_eq "carried backup restores the original database" "$(cat "$RS/data/dashboard/dashboard.db")" DBDATA-ORIG
assert_eq "carried backup consumes its passphrase" "$([ -e "$RPSEED/pithead-restore-pass" ] || echo gone)" gone
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
cp "$RS/unexpected.tar.gz" "$RPSEED/pithead-restore.enc"
printf '' >"$RPSEED/pithead-restore-pass"
out=$(PITHEAD_PRESEED_DIR="$RPSEED" run_sourced "$RS" eval 'mount() { :; }; consume_preseed_restore || echo "rc$?"' 2>&1)
assert_contains "carried backup refuses an unexpected regular member" "$out" rc1
assert_contains "carried member refusal identifies the backup layout" "$out" 'outside the appliance backup layout'
assert_eq "member refusal applies no valid files beside the invalid member" "$(cat "$RS/Caddyfile")" CADDY-ORIG
assert_eq "rejected carried backup is consumed" "$([ -e "$RPSEED/pithead-restore.enc" ] || echo gone)" gone
rm -f "$RSPOOL/error.txt"

# 2) Bad passphrase: rejected before anything is touched.
printf 'CORRUPTED\n' >"$RS/Caddyfile"
cp "$rarchive" "$RSPOOL/restore-archive"
printf 'not-the-passphrase' >"$RSPOOL/restore-passphrase" # test fixture
out=$(run_sourced "$RS" firstboot_consume_restore "$RSPOOL" || echo "rc$?")
assert_contains "wrong passphrase rejected" "$out" "rc1"
assert_contains "wrong passphrase names the cause" "$(cat "$RSPOOL/error.txt" 2>/dev/null)" "assphrase"
assert_eq "wrong passphrase leaves live files untouched" "$(cat "$RS/Caddyfile")" "CORRUPTED"
assert_eq "the archive is consumed even on rejection" "$([ -f "$RSPOOL/restore-archive" ] || echo gone)" "gone"
assert_eq "the passphrase is never retained even on rejection" "$([ -f "$RSPOOL/restore-passphrase" ] || echo gone)" "gone"
printf 'CADDY-ORIG\n' >"$RS/Caddyfile"
rm -f "$RSPOOL/error.txt"

# 3) Encrypted archive, no passphrase supplied at all.
cp "$rarchive" "$RSPOOL/restore-archive"
out=$(run_sourced "$RS" firstboot_consume_restore "$RSPOOL" || echo "rc$?")
assert_contains "missing passphrase rejected" "$out" "rc1"
assert_contains "missing passphrase names the cause" "$(cat "$RSPOOL/error.txt" 2>/dev/null)" "passphrase"
rm -f "$RSPOOL/error.txt"

# 4) Oversize: refused on SIZE alone, before any decrypt/extract — content is irrelevant.
truncate -s 67108865 "$RSPOOL/restore-archive"
printf 'hunter2' >"$RSPOOL/restore-passphrase" # test fixture
out=$(run_sourced "$RS" firstboot_consume_restore "$RSPOOL" || echo "rc$?")
assert_contains "oversize archive rejected" "$out" "rc1"
assert_contains "oversize archive names the cap" "$(cat "$RSPOOL/error.txt" 2>/dev/null)" "too large"
rm -f "$RSPOOL/error.txt"

# 5) Malformed: neither the encrypted magic nor gzip's — falls back exactly like a rejected
# config, never blocking setup.
printf 'garbage-not-an-archive' >"$RSPOOL/restore-archive"
printf 'hunter2' >"$RSPOOL/restore-passphrase" # test fixture
out=$(run_sourced "$RS" firstboot_consume_restore "$RSPOOL" || echo "rc$?")
assert_contains "malformed archive rejected" "$out" "rc1"
assert_contains "malformed archive names the problem" "$(cat "$RSPOOL/error.txt" 2>/dev/null)" "not a Pithead backup archive"
assert_eq "malformed archive leaves config.json untouched" "$([ -f "$RS/config.json" ] || echo gone)" "gone"
rm -f "$RSPOOL/error.txt"

# 6) Path-traversal / symlink defense: a well-formed gzip archive (passes the magic + integrity
# checks) whose members escape the restore set must be refused BEFORE anything is staged to "/".
# A Pithead backup is only regular files under known prefixes, so a symlink or a ".." member is an
# attack. Built with real tar so the guard faces the exact bytes it would on a box.
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
# Absolute-path member (stored with a leading slash via -P): would land at /… on cp -a.
printf 'EVIL\n' >"$MAL/evil"
(cd "$MAL" && tar -Pczf "$RSPOOL/restore-archive" "$MAL/evil") 2>/dev/null
out=$(run_sourced "$RS" firstboot_consume_restore "$RSPOOL" || echo "rc$?")
assert_contains "an absolute-path member is refused" "$out" "rc1"
rm -f "$RSPOOL/error.txt"

# 7) Nothing to consume.
out=$(run_sourced "$RS" firstboot_consume_restore "$RSPOOL" || echo "rc$?")
assert_contains "empty spool is rc2" "$out" "rc2"
rm -rf "$RS"

echo "== black-box: uninstall keeps the operator's files (#77 phase 1) =="
# Self-provision a fully-rendered .env rather than relying on an earlier section's ambient one:
# this used to inherit it for free from the dashboard-auth-lifecycle black-box, which ran
# immediately before this section in the original file; that test now lives in
# test-dashboard.sh (#1105 Phase 1), sourced far earlier, so a LATER config-validation case
# (a rejected apply, whose own seed_env leaves .env at the bare pre-render baseline — no
# *_DATA_DIR keys) was the last thing to touch .env by the time this section ran. stack_uninstall
# greps .env for those keys with `pipefail` under `set -e`; zero matches makes that grep — not
# uninstall's own logic — abort the whole script. Render a real, complete .env here so this
# section proves uninstall's OWN behaviour instead of depending on a same-file predecessor.
seed_env
printf '{ "monero": {"mode":"local","wallet_address":"%s","node_username":"u","node_password":"p"}, "tari":{"wallet_address":"'"$VALID_TARI"'"}, "p2pool":{"pool":"main"}, "dashboard":{"secure":true,"host":"box.lan"} }\n' "$WALLET" >"$V/config.json"
kept_dir="$V/"'kept $literal'
jq --arg dir "$kept_dir" '.monero.data_dir = $dir' "$V/config.json" >"$V/config.json.tmp" && mv "$V/config.json.tmp" "$V/config.json"
out="$(cd "$V" && PATH="$V/bin:$PATH" ./pithead apply -y 2>&1)"
rc=$?
assert_rc "uninstall fixture: self-provisioned apply succeeds" "$rc" "0"
# Without confirmation: aborts, changes nothing.
touch "$V/Caddyfile"
out=$(cd "$V" && printf 'no\n' | PATH="$V/bin:$PATH" ./pithead uninstall 2>&1) || true
assert_contains "uninstall aborts without the confirm word" "$out" "Aborted"
assert_eq "aborted uninstall keeps .env" "$([ -f "$V/.env" ] && echo yes)" "yes"
# With -y: rendered files go, the operator's files stay.
out=$(cd "$V" && PATH="$V/bin:$PATH" ./pithead uninstall -y 2>&1)
assert_contains "uninstall names the kept files" "$out" "config.json"
assert_contains "uninstall displays the decoded data path" "$out" "$kept_dir"
assert_eq "uninstall removes .env" "$([ -f "$V/.env" ] || echo gone)" "gone"
assert_eq "uninstall removes Caddyfile" "$([ -f "$V/Caddyfile" ] || echo gone)" "gone"
assert_eq "uninstall keeps config.json" "$([ -f "$V/config.json" ] && echo yes)" "yes"
out=$(cd "$V" && PATH="$V/bin:$PATH" ./pithead uninstall --bogus 2>&1) || true
assert_contains "uninstall rejects unknown options" "$out" "Unknown option"
# Re-render the sandbox .env for the sections below — uninstall just deleted it.
seed_env
printf '{ "monero": {"mode":"local","wallet_address":"%s","node_username":"u","node_password":"p"}, "tari":{"wallet_address":"'"$VALID_TARI"'"}, "p2pool":{"pool":"main"}, "dashboard":{"secure":true,"host":"box.lan"} }\n' "$WALLET" >"$V/config.json"
out="$(cd "$V" && PATH="$V/bin:$PATH" ./pithead apply -y 2>&1)"

echo "== unit: a failed wizard setup hands back a machine that can be re-provisioned (#2050) =="
# setup's second render_env writes DEPLOYMENT_COMPLETED=true about a third of the way in — long
# before provision_control_runner, generate_caddyfile or the `up` that finishes it. Every failure
# past that point left the marker standing on a machine that is NOT deployed, so the retry
# wizard_keep_failed_config exists to enable could never run: setup's own is_deployed guard
# refuses headless with "Already provisioned … run from a terminal" (#924), and the reopened page
# died on that same refusal however the operator corrected their answers. Same marker, same
# reason, and the same clear restore_apply already makes on the carried-.env door (#1239).
WKFD="$SANDBOX/wizard-failed-deploy"
wkfd_reset() { # writes a machine-role so the keep takes the KEEP branch, not the re-arm one
    rm -rf "$WKFD"
    mkdir -p "$WKFD"
    cp "$STACK" "$WKFD/pithead"
    printf '{"submitted":"the operator answers"}\n' >"$WKFD/config.json"
    printf 'pithead\n' >"$WKFD/machine-role"
}
# A SECOND true-valued key beside the marker, so the substitution is pinned to the one it means:
# a blanket s/true/false/ would also flip DASHBOARD_SECURE and still pass a marker-only assertion
# while silently downgrading the machine to plain HTTP.
wkfd_reset
printf 'DASHBOARD_SECURE=true\nDEPLOYMENT_COMPLETED=true\nHOST_IP=10.0.0.2\n' >"$WKFD/.env"
run_sourced "$WKFD" wizard_keep_failed_config >/dev/null 2>&1
assert_rc "the keep still reports success while clearing the marker" "$?" "0"
assert_eq "a failed setup clears the deployment marker so a retry can provision" \
    "$(grep '^DEPLOYMENT_COMPLETED=' "$WKFD/.env")" "DEPLOYMENT_COMPLETED=false"
assert_eq "and touches no other key that happens to say true" \
    "$(grep '^DASHBOARD_SECURE=' "$WKFD/.env")" "DASHBOARD_SECURE=true"
# The negative half: nothing to clear must also mean nothing to create. An .env conjured here
# would hold only DEPLOYMENT_COMPLETED=false, which the required-key reads (#1246) treat as a
# corrupt file rather than the absent one it really is.
wkfd_reset
run_sourced "$WKFD" wizard_keep_failed_config >/dev/null 2>&1
assert_rc "the keep succeeds on a machine that never rendered an .env" "$?" "0"
assert_eq "no .env is created by the failure path" "$([ -e "$WKFD/.env" ] || echo absent)" "absent"
rm -rf "$WKFD"
